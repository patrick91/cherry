import AppKit
import CherryControl
import SwiftUI

// How a window on another Mac (a device window, `device:<uuid>:<path>`)
// says so: each device's colour (`RemoteDeviceColor`, chosen in Settings ›
// Sessions › Other Macs or derived from its id), the Mac chip under the
// sidebar header's project name, the Mac-name prefix of the tab header's
// path, a thin tinted line along the window's top edge, and the window
// title. This Mac's windows show none of it.

/// A device's colour: a small palette that reads in light and dark and
/// stays clear of the sidebar's selection purple (no violet or indigo).
enum RemoteDeviceColor: String, Codable, CaseIterable, Identifiable, Sendable {
    case blue
    case cyan
    case teal
    case green
    case amber
    case orange
    case red
    case rose

    var id: String { rawValue }

    var title: String {
        switch self {
        case .blue: "Blue"
        case .cyan: "Cyan"
        case .teal: "Teal"
        case .green: "Green"
        case .amber: "Amber"
        case .orange: "Orange"
        case .red: "Red"
        case .rose: "Rose"
        }
    }

    /// Darker on light backgrounds, lighter on dark ones, so text in it
    /// stays readable in both.
    var lightHexRGB: String {
        switch self {
        case .blue: "#2563EB"
        case .cyan: "#0E7490"
        case .teal: "#0F766E"
        case .green: "#15803D"
        case .amber: "#B45309"
        case .orange: "#C2410C"
        case .red: "#DC2626"
        case .rose: "#E11D48"
        }
    }

    var darkHexRGB: String {
        switch self {
        case .blue: "#60A5FA"
        case .cyan: "#22D3EE"
        case .teal: "#2DD4BF"
        case .green: "#4ADE80"
        case .amber: "#FBBF24"
        case .orange: "#FB923C"
        case .red: "#F87171"
        case .rose: "#FB7185"
        }
    }

    func nsColor(for colorScheme: ColorScheme) -> NSColor {
        NSColor(hexRGB: colorScheme == .dark ? darkHexRGB : lightHexRGB) ?? .controlAccentColor
    }

    func color(for colorScheme: ColorScheme) -> Color {
        Color(nsColor: nsColor(for: colorScheme))
    }

    /// The colour a device without a chosen one gets: the same for the same
    /// id on every run and every Mac (FNV-1a over its UUID's bytes, never
    /// Swift's per-process hash).
    static func automatic(for id: UUID) -> RemoteDeviceColor {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        withUnsafeBytes(of: id.uuid) { bytes in
            for byte in bytes {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01b3
            }
        }
        return allCases[Int(hash % UInt64(allCases.count))]
    }
}

extension RemoteDevice {
    /// Its chosen colour, else its automatic one.
    var effectiveColor: RemoteDeviceColor {
        color ?? RemoteDeviceColor.automatic(for: id)
    }
}

/// What a device window shows of its Mac: its name and colour.
struct RemoteDeviceBadge: Equatable, Sendable {
    static let unknownName = "Unknown Mac"

    let deviceID: UUID
    let name: String
    let color: RemoteDeviceColor

    init(deviceID: UUID, name: String, color: RemoteDeviceColor) {
        self.deviceID = deviceID
        self.name = name
        self.color = color
    }

    init(device: RemoteDevice) {
        self.init(deviceID: device.id, name: device.name, color: device.effectiveColor)
    }

    /// A laptop for a Mac whose name says it is one, else a display.
    var symbolName: String {
        let name = name.lowercased()
        return name.contains("book") || name.contains("laptop") ? "laptopcomputer" : "desktopcomputer"
    }

    /// The badge of the Mac a project key names; nil for This Mac's keys
    /// (the store is never asked then). A device the store no longer knows
    /// still gets one ("Unknown Mac"), so its window still says it is not
    /// This Mac's.
    @MainActor
    static func forProjectKey(_ key: String?, devices: [RemoteDevice]) -> RemoteDeviceBadge? {
        guard let key, let deviceID = ProjectLocation(key: key).deviceID else { return nil }
        if let device = devices.first(where: { $0.id == deviceID }) { return RemoteDeviceBadge(device: device) }
        return RemoteDeviceBadge(deviceID: deviceID, name: unknownName, color: .automatic(for: deviceID))
    }
}

/// The window title (Window menu, Mission Control, ⌘`): "<project>",
/// "<project> / <worktree>", with " — <Mac>" for a device window, and
/// " — <tab>" when its selected tab has a title.
enum ProjectWindowTitle {
    static func title(project: String, worktree: String? = nil, deviceName: String? = nil, tab: String? = nil) -> String {
        var title = project
        if let worktree, !worktree.isEmpty { title += " / \(worktree)" }
        if let deviceName, !deviceName.isEmpty { title += " — \(deviceName)" }
        let tab = tab?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !tab.isEmpty { title += " — \(tab)" }
        return title
    }
}

extension EnvironmentValues {
    /// The device store a device window's views read their Mac from. Only
    /// device windows set it (to `RemoteDeviceStore.shared`); tests set
    /// their own. Nil elsewhere: This Mac's windows never ask a store.
    @Entry var remoteDeviceStore: RemoteDeviceStore? = nil
}

/// Gives `content` the badge of the Mac `projectKey` names (nil for This
/// Mac's, or without a store in the environment), kept current as the
/// device is renamed or recoloured.
struct RemoteDeviceBadgeReader<Content: View>: View {
    @Environment(\.remoteDeviceStore) private var store
    let projectKey: String?
    @ViewBuilder let content: (RemoteDeviceBadge?) -> Content

    var body: some View {
        if let store, let projectKey, ProjectLocation.isRemoteKey(projectKey) {
            Observing(store: store, projectKey: projectKey, content: content)
        } else {
            content(nil)
        }
    }

    private struct Observing: View {
        @ObservedObject var store: RemoteDeviceStore
        let projectKey: String
        let content: (RemoteDeviceBadge?) -> Content

        var body: some View {
            content(RemoteDeviceBadge.forProjectKey(projectKey, devices: store.devices))
        }
    }
}

/// The sidebar header's Mac chip: a display (or laptop) and the Mac's
/// name, in its colour.
struct RemoteDeviceHeaderChip: View {
    static let fontSize: CGFloat = 11
    static let symbolWidth: CGFloat = 13
    static let spacing: CGFloat = 3
    static let horizontalPadding: CGFloat = 5

    @Environment(\.colorScheme) private var colorScheme
    let badge: RemoteDeviceBadge

    var body: some View {
        let tint = badge.color.color(for: colorScheme)
        HStack(spacing: Self.spacing) {
            Image(systemName: badge.symbolName)
                .font(.system(size: 9, weight: .semibold))
                .frame(width: Self.symbolWidth)
            Text(badge.name)
                .font(.system(size: Self.fontSize, weight: .semibold))
                .lineLimit(1)
                .truncationMode(.tail)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, Self.horizontalPadding)
        .background(Capsule(style: .continuous).fill(tint.opacity(0.14)))
        .fixedSize(horizontal: false, vertical: true)
        .background(RemoteDeviceChipAnchor())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("On \(badge.name)")
    }

    private static let font = NSFont.systemFont(ofSize: fontSize, weight: .semibold)

    /// Its width, for the header's own measuring.
    static func width(of badge: RemoteDeviceBadge) -> CGFloat {
        let text = ceil((badge.name as NSString).size(withAttributes: [.font: font]).width)
        return symbolWidth + spacing + text + horizontalPadding * 2
    }
}

/// Marks the Mac chip for tests that look for it.
private struct RemoteDeviceChipAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.identifier = .remoteDeviceChipAnchor
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension NSUserInterfaceItemIdentifier {
    static let remoteDeviceChipAnchor = NSUserInterfaceItemIdentifier("Cherry.RemoteDeviceChipAnchor")
}

/// A device window's thin tinted line along the top edge of its content
/// (under the transparent title bar). Never takes clicks.
struct RemoteDeviceAccentLine: View {
    static let height: CGFloat = 2

    @Environment(\.colorScheme) private var colorScheme
    let projectKey: String

    var body: some View {
        RemoteDeviceBadgeReader(projectKey: projectKey) { badge in
            if let badge {
                Rectangle()
                    .fill(badge.color.color(for: colorScheme).opacity(0.85))
                    .frame(height: Self.height)
                    .frame(maxWidth: .infinity)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Settings › Sessions › Other Macs: a device's colour, Automatic or one
/// of the palette's.
struct RemoteDeviceColorPicker: View {
    @Environment(\.colorScheme) private var colorScheme
    let deviceID: UUID
    let selection: RemoteDeviceColor?
    let isEnabled: Bool
    let choose: (RemoteDeviceColor?) -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button { choose(nil) } label: {
                HStack(spacing: 4) {
                    swatch(RemoteDeviceColor.automatic(for: deviceID), selected: selection == nil)
                    Text("Automatic").font(.callout)
                }
            }
            .buttonStyle(.plain)
            .help("Automatic: a colour picked from this Mac's identity")
            .accessibilityLabel("Automatic colour")
            .accessibilityAddTraits(selection == nil ? .isSelected : [])

            Divider().frame(height: 14)

            ForEach(RemoteDeviceColor.allCases) { color in
                Button { choose(color) } label: { swatch(color, selected: selection == color) }
                    .buttonStyle(.plain)
                    .help(color.title)
                    .accessibilityLabel(color.title)
                    .accessibilityAddTraits(selection == color ? .isSelected : [])
            }
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
    }

    private func swatch(_ color: RemoteDeviceColor, selected: Bool) -> some View {
        Circle()
            .fill(color.color(for: colorScheme))
            .frame(width: 12, height: 12)
            .padding(2)
            .overlay(Circle().strokeBorder(selected ? Color.primary.opacity(0.7) : .clear, lineWidth: 1.5))
            .contentShape(Circle())
    }
}
