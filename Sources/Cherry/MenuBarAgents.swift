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

struct MenuBarAgentPresentation {
    static func projectName(projectRoot: String) -> String {
        let name = CherryProject(root: projectRoot).name
        return name.isEmpty ? "Cherry" : name
    }

    static func agentTitle(
        title: String,
        titleSource: TerminalSession.TitleSource,
        agentName: String?,
        commandLine: String
    ) -> String {
        SidebarAgentTitleFormatter.title(
            title: title,
            titleSource: titleSource,
            agentName: agentName,
            commandLine: commandLine
        )
    }
}

// MARK: - Model

struct MenuBarShimmerSettings: Equatable {
    // Baked from the in-app design panel (Speed 1.9×, Pulse 40%, Peak 93%, Base 59%,
    // Stagger 5% ≈ 71 ms). All values are fractions of the shimmer cycle except `duration`.
    var duration: Double = 2.7 / 1.9   // 1.9× the 2.7 s reference cycle
    var pulseWidth: Double = 0.4       // each layer's highlight lasts 40% of the cycle
    var peakAlpha: Double = 0.93       // brightest alpha at the pulse peak
    var baseAlpha: Double = 0.59       // resting alpha
    var layerStagger: Double = 0.05    // delay between adjacent layers (drives top→bottom sweep)

    var cacheKey: String {
        [duration, pulseWidth, peakAlpha, baseAlpha, layerStagger]
            .map { String(Int(($0 * 1_000).rounded())) }
            .joined(separator: ":")
    }
}

/// Drives the working-state shimmer of the menu-bar glyph: small highlight
/// sweeps across the stack layers.
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
/// One timer tick per frame: quantizing the shimmer keeps the tick rate bounded
/// and gives every frame a stable cache key, so the label can reuse a small set of
/// NSImages instead of baking a fresh symbol image per timer tick.
@MainActor
final class MenuBarShimmerModel: ObservableObject {
    static let shared = MenuBarShimmerModel()

    @Published private(set) var frame = 0
    let settings = MenuBarShimmerSettings()

    private var timer: Timer?
    private var step = 0
    private var hasWorkingAgents = false
    // A ~1.4s sweep at ~13 ticks/s: every status-item update costs real main-thread
    // time (label snapshot → setImage → length adjust), so the shimmer is quantized to
    // a fixed frame table — a bounded tick rate that still reads as motion, and a
    // stable per-frame cache key so the label reuses a small set of NSImages.
    static let frameCount = 18

    func setWorkingAgentsActive(_ active: Bool) {
        guard hasWorkingAgents != active else { return }
        hasWorkingAgents = active
        reconcileTimer(resetFrame: active)
    }

    private func reconcileTimer(resetFrame: Bool) {
        if hasWorkingAgents {
            if resetFrame {
                step = 0
                frame = 0
            }
            if timer == nil {
                startTimer()
            }
        } else {
            stopTimer(resetFrame: true)
        }
    }

    private func startTimer() {
        let interval = max(0.05, settings.duration / Double(Self.frameCount))
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] timer in
            guard let self else {
                timer.invalidate()
                return
            }
            MainActor.assumeIsolated {
                self.step = (self.step + 1) % Self.frameCount
                self.frame = self.step
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func stopTimer(resetFrame: Bool) {
        timer?.invalidate()
        timer = nil
        if resetFrame {
            step = 0
            frame = 0
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
                let brand = AgentToolBrand.detect(
                    name: session.agentName ?? session.title,
                    commandLine: session.subtitle
                )
                return MenuBarAgentItem(
                    id: session.id,
                    projectRoot: root,
                    title: MenuBarAgentPresentation.agentTitle(
                        title: session.title,
                        titleSource: session.titleSource,
                        agentName: session.agentName,
                        commandLine: session.subtitle
                    ),
                    agentKey: brand?.rawValue
                        ?? AgentToolDefinition.normalizedName(session.agentName ?? session.title),
                    activity: session.agentActivityState
                )
            }
            groups.append(MenuBarProjectGroup(
                projectRoot: root,
                projectName: MenuBarAgentPresentation.projectName(projectRoot: root),
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
        MenuBarShimmerModel.shared.setWorkingAgentsActive(aggregate == .working)
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
    @ObservedObject private var shimmer = MenuBarShimmerModel.shared
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Image(nsImage: Self.cachedIcon(
            for: model.aggregate,
            dark: colorScheme == .dark,
            shimmerFrame: shimmer.frame,
            settings: shimmer.settings
        ))
            .accessibilityLabel("Cherry agents")
    }

    // Reuse one NSImage per (state, appearance, shimmer frame): the shimmer revisits
    // the same frame table every cycle, and handing AppKit the same instance lets its
    // symbol rasterization cache hit instead of re-rendering a fresh image per frame.
    @MainActor private static var iconCache: [String: NSImage] = [:]

    @MainActor
    private static func cachedIcon(
        for state: MenuBarAggregateState,
        dark: Bool,
        shimmerFrame: Int,
        settings: MenuBarShimmerSettings
    ) -> NSImage {
        let normalizedFrame = state == .working ? shimmerFrame % MenuBarShimmerModel.frameCount : 0
        let settingsKey = state == .working ? settings.cacheKey : "static"
        let key = "\(state)|\(dark)|\(normalizedFrame)|\(settingsKey)"
        if let cached = iconCache[key] { return cached }
        let image: NSImage
        if state == .working {
            image = workingIcon(dark: dark, frame: normalizedFrame, settings: settings)
        } else {
            image = glyphImage(layerColors: paletteColors(for: state, dark: dark))
        }
        if iconCache.count > 240 {
            iconCache.removeAll(keepingCapacity: true)
        }
        iconCache[key] = image
        return image
    }

    // The working glyph is drawn from three stacked plate polygons (see `layerPaths`),
    // so it has three real, independently-tintable layers — top (0), middle (1),
    // bottom (2). This is why we draw the gem ourselves instead of using
    // `square.stack.3d.up.fill`, which only exposes two palette layers.
    private static let stackLayerCount = 3

    // The state is carried by the glyph itself: idle / no-agents stay monochrome,
    // working shimmers each plate over a dim base, and needs-input / error tint the
    // whole gem orange / red. Every state renders through the same three-plate glyph
    // (mono states pass a single color that fills every plate) so the icon never
    // changes size between states. MenuBarExtra flattens a colored SwiftUI label to a
    // template, so the image is baked non-template; the glyph color follows the
    // current appearance.
    private static func paletteColors(for state: MenuBarAggregateState, dark: Bool) -> [NSColor] {
        let glyph: NSColor = dark ? .white : NSColor(white: 0.12, alpha: 1)
        switch state {
        case .none, .idle: return [glyph]
        case .working: return [glyph]
        case .attention: return [.systemOrange]
        case .error: return [.systemRed]
        }
    }

    // A highlight sweeps top → bottom through the stack: each layer rides its own
    // staggered copy of the same rest → peak → rest pulse, so the three planes light
    // up one after another. Purely a palette-alpha modulation — no per-frame
    // compositing — which keeps every frame a cheap symbol re-render.
    @MainActor
    private static func workingIcon(dark: Bool, frame: Int, settings: MenuBarShimmerSettings) -> NSImage {
        let glyph: NSColor = dark ? .white : NSColor(white: 0.12, alpha: 1)
        let phase = CGFloat(frame) / CGFloat(MenuBarShimmerModel.frameCount)
        let base = CGFloat(settings.baseAlpha)
        let peak = CGFloat(settings.peakAlpha)
        let width = CGFloat(settings.pulseWidth)
        let stagger = CGFloat(settings.layerStagger)

        let colors: [NSColor] = (0..<stackLayerCount).map { layer in
            let layerPhase = wrappedPhase(phase - CGFloat(sweepOrder(layer)) * stagger)
            let pulse = layerPulse(layerPhase, width: width)
            let alpha = base + (peak - base) * pulse
            return glyph.withAlphaComponent(min(1, max(0, alpha)))
        }
        return glyphImage(layerColors: colors)
    }

    // Plate 0 is the top of the gem, so pulsing in plate order sweeps the highlight
    // top → bottom. Return `stackLayerCount - 1 - layer` to reverse it.
    private static func sweepOrder(_ layer: Int) -> Int {
        layer
    }

    // The prototype's `layer-wave` curve as a scalar: 0 at rest, ramps to 1 at 40% of
    // the pulse window, falls back to 0 by the end of the window, then holds at rest.
    private static func layerPulse(_ phase: CGFloat, width: CGFloat) -> CGFloat {
        guard phase > 0, phase < width else { return 0 }
        let peakAt = width * 0.4
        let t = phase < peakAt ? phase / peakAt : 1 - (phase - peakAt) / (width - peakAt)
        return smoothstep(t)
    }

    // Cubic smoothstep — an ease-in-out that matches the prototype's CSS timing.
    private static func smoothstep(_ t: CGFloat) -> CGFloat {
        let x = min(max(t, 0), 1)
        return x * x * (3 - 2 * x)
    }

    private static func wrappedPhase(_ phase: CGFloat) -> CGFloat {
        let wrapped = phase.truncatingRemainder(dividingBy: 1)
        return wrapped < 0 ? wrapped + 1 : wrapped
    }

    // The Cherry brandmark's three stacked layers, exported from Figma
    // (file SVyjAEhWW272P9Ys90L1Ra, node 42:75 — the shorter variant) as an SVG whose
    // viewBox is the artwork's own bounds (14.66×13.87). Ordered top → bottom: `Top` is
    // a rounded square tilted into an isometric diamond; `Middle`/`Bottom` are the
    // chevron "wings". Drawing them ourselves — not an SF symbol — keeps each a real,
    // independently-tintable shape for the shimmer.
    private static let middleLayerPath = "M13.7745 6.65273C14.2127 6.87622 14.2127 7.23857 13.7745 7.46205L8.03166 10.3903C7.59342 10.6138 6.88254 10.6138 6.44429 10.3903L0.701486 7.46205C0.263239 7.23856 0.263239 6.87622 0.701486 6.65273L1.0358 6.48175C1.31945 6.33669 1.66922 6.3365 1.95307 6.48125L6.44429 8.77167C6.88254 8.99516 7.59342 8.99516 8.03166 8.77167L12.5222 6.48117C12.8059 6.33646 13.1556 6.33656 13.4392 6.48144L13.7745 6.65273Z"
    private static let bottomLayerPath = "M13.7745 9.96604C14.2127 10.1895 14.2127 10.5519 13.7745 10.7754L8.03166 13.7036C7.59342 13.9271 6.88254 13.9271 6.44429 13.7036L0.701486 10.7754C0.263239 10.5519 0.263239 10.1895 0.701486 9.96604L1.0358 9.79506C1.31945 9.65 1.66922 9.64981 1.95307 9.79456L6.44429 12.085C6.88254 12.3085 7.59342 12.3085 8.03166 12.085L12.5222 9.79448C12.8059 9.64977 13.1556 9.64987 13.4392 9.79475L13.7745 9.96604Z"

    // Points per source unit. The art is exported at its final menu-bar size, so we
    // render 1:1 rather than stretching it to fill — that's what lets a "shorter" Figma
    // variant read shorter. Raise this to scale the whole glyph uniformly.
    private static let glyphScale: CGFloat = 1
    private static let glyphPadding: CGFloat = 1

    // Build the three layer shapes in the source viewBox (y-down), ordered top → bottom
    // to match the incoming `layerColors`.
    private static func brandmarkLayers() -> [NSBezierPath] {
        let top = NSBezierPath(
            roundedRect: NSRect(x: 0, y: 0, width: 8.22825, height: 8.2284),
            xRadius: 1,
            yRadius: 1
        )
        // Figma's matrix(0.89085 0.454298 -0.89085 0.454298 7.33031 0.000239) tilts the
        // square into the isometric diamond and positions it.
        top.transform(using: AffineTransform(m11: 0.89085, m12: 0.454298, m21: -0.89085, m22: 0.454298, tX: 7.33031, tY: 0.000238533))
        return [top, parseSVGPath(middleLayerPath), parseSVGPath(bottomLayerPath)]
    }

    // Union bounds of the assembled artwork, in source coordinates (computed once).
    private static let brandmarkBounds: NSRect = {
        let layers = brandmarkLayers()
        return layers.dropFirst().reduce(layers[0].bounds) { $0.union($1.bounds) }
    }()

    // Draw the brandmark at `glyphScale`, filling each layer with its color
    // (`layerColors` runs top → bottom; fewer colors than layers repeats the last),
    // painting bottom → top like the source art. The image is sized to the artwork plus
    // a little padding and the menu bar centres it; the handler re-runs per scale so it
    // stays crisp on Retina.
    @MainActor
    private static func glyphImage(layerColors: [NSColor]) -> NSImage {
        let box = brandmarkBounds
        let size = NSSize(
            width: box.width * glyphScale + glyphPadding * 2,
            height: box.height * glyphScale + glyphPadding * 2
        )
        // Source (y-down) → image (y-up): scale, flip, drop the box origin, pad.
        let transform = AffineTransform(
            m11: glyphScale, m12: 0, m21: 0, m22: -glyphScale,
            tX: glyphPadding - box.minX * glyphScale,
            tY: size.height - glyphPadding + box.minY * glyphScale
        )
        let image = NSImage(size: size, flipped: false) { _ in
            let layers = brandmarkLayers()
            for layer in layers { layer.transform(using: transform) }
            for index in layers.indices.reversed() {
                layerColors[min(index, layerColors.count - 1)].setFill()
                layers[index].fill()
            }
            return true
        }
        image.isTemplate = false
        return image
    }

    // Minimal parser for the exported layer paths: absolute M / L / C / Z commands,
    // built in the source's own coordinate space.
    private static func parseSVGPath(_ definition: String) -> NSBezierPath {
        var spaced = ""
        for character in definition {
            if "MLCZmlcz".contains(character) { spaced += " \(character) " } else { spaced.append(character) }
        }
        let tokens = spaced.split(whereSeparator: { $0 == " " || $0 == "," })
        let path = NSBezierPath()
        var index = 0
        var command: Character = "M"
        func nextValue() -> CGFloat {
            defer { index += 1 }
            return index < tokens.count ? CGFloat(Double(tokens[index]) ?? 0) : 0
        }
        while index < tokens.count {
            let start = index
            if tokens[index].count == 1, let letter = tokens[index].first, "MLCZmlcz".contains(letter) {
                command = letter
                index += 1
            }
            switch command {
            case "M", "m":
                path.move(to: NSPoint(x: nextValue(), y: nextValue()))
                command = "L"
            case "L", "l":
                path.line(to: NSPoint(x: nextValue(), y: nextValue()))
            case "C", "c":
                let control1 = NSPoint(x: nextValue(), y: nextValue())
                let control2 = NSPoint(x: nextValue(), y: nextValue())
                let end = NSPoint(x: nextValue(), y: nextValue())
                path.curve(to: end, controlPoint1: control1, controlPoint2: control2)
            case "Z", "z":
                path.close()
            default:
                break
            }
            if index == start { index += 1 }
        }
        return path
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
                Text(group.projectName)
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
        AgentToolBrand(rawValue: key)?.logoResourceName
            ?? AgentToolBrand.detect(name: key)?.logoResourceName
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
