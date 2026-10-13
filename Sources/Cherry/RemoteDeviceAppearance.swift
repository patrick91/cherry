import AppKit
import CherryControl
import SwiftUI

// How a window on another Mac (a device window, `device:<uuid>:<path>`)
// says so: each device's colour (`RemoteDeviceColor`, chosen in Settings ›
// Sessions › Other Macs or derived from its id), "@ <Mac>" after the
// sidebar header's project name (which also shows whether the Mac answers),
// the Mac-name prefix of the tab header's path, and the window title
// "<project> @ <Mac>". The Mac is named once per place: tab rows do not
// repeat it. This Mac's windows show none of it.

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

/// The window title (Window menu, Mission Control, ⌘`): "<project>", with
/// " @ <Mac>" for a device window, as its header says it, and " — <tab>"
/// when its selected tab has a title.
enum ProjectWindowTitle {
    static func title(project: String, deviceName: String? = nil, tab: String? = nil) -> String {
        var title = project
        if let deviceName, !deviceName.isEmpty { title += " @ \(deviceName)" }
        let tab = tab?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !tab.isEmpty { title += " — \(tab)" }
        return title
    }
}

extension EnvironmentValues {
    /// The device store a device window's views read their Mac from. Only
    /// device windows set it (to `RemoteDeviceStore.shared`); tests set
    /// their own. Nil elsewhere: This Mac's windows never ask a store.
    var remoteDeviceStore: RemoteDeviceStore? {
        get { self[RemoteDeviceStoreKey.self] }
        set { self[RemoteDeviceStoreKey.self] = newValue }
    }
}

/// Spelled out rather than `@Entry`: that macro's plugin ships only with
/// Xcode, so the Command Line Tools alone could not build Cherry.
private struct RemoteDeviceStoreKey: EnvironmentKey {
    static let defaultValue: RemoteDeviceStore? = nil
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

/// Whether a device window's Mac answers, as its header shows it: the name
/// in its colour, dimmed while it reconnects, grey with a warning when the
/// user has to act (the tab's or the window's bar says how).
enum RemoteDeviceHeaderStatus: Equatable {
    /// Connected, or not asked to connect (a window with no tabs leases
    /// no connection): nothing to say.
    case normal
    case reconnecting
    /// What stands in the way (`RemoteDeviceAvailability.text`).
    case needsYou(String)

    static func of(_ state: HostControl.ConnectionState, installationProblem: String?, machine: String) -> Self {
        if installationProblem == nil, state == .idle { return .normal }
        switch RemoteDeviceAvailability.of(state, installationProblem: installationProblem) {
        case .online: return .normal
        case .reconnecting: return .reconnecting
        case let availability: return .needsYou(availability.text(machine: machine))
        }
    }

    /// The header's help and spoken text after "<project> on <Mac>".
    func detail(machine: String) -> String? {
        switch self {
        case .normal: nil
        case .reconnecting: "Reconnecting to \(machine)…"
        case .needsYou(let text): text
        }
    }
}

/// Gives `content` the header status of `hosting`'s Mac (`.normal` without
/// one), kept current as its control connects, drops and retries.
struct RemoteDeviceStatusReader<Content: View>: View {
    let hosting: PersistentHostSessions?
    @ViewBuilder let content: (RemoteDeviceHeaderStatus) -> Content

    var body: some View {
        if let hosting {
            Observing(hosting: hosting, control: hosting.control, content: content)
        } else {
            content(.normal)
        }
    }

    private struct Observing: View {
        let hosting: PersistentHostSessions
        @ObservedObject var control: HostControl
        let content: (RemoteDeviceHeaderStatus) -> Content

        var body: some View {
            content(RemoteDeviceHeaderStatus.of(
                control.state,
                // A device Cherry no longer knows: its stand-in says why.
                installationProblem: hosting.profile.isKnownDevice ? nil : hosting.installationProblem(),
                machine: hosting.profile.displayName
            ))
        }
    }
}

/// What follows the project name in a device window's sidebar header:
/// "@ <Mac>", the name in its Mac's colour. While the Mac reconnects the
/// name dims (and pulses for a while, unless Reduce Motion is on); when
/// the user has to act it turns grey and a warning follows it. The name
/// truncates before the project's does.
struct RemoteDeviceHeaderAddress: View {
    static let spacing: CGFloat = 4
    static let warningWidth: CGFloat = 13
    /// Room the name keeps when the project's name is long ("pat…").
    static let minimumNameWidth: CGFloat = 30
    /// Pulses, then stays dim: a Mac asleep for hours does not animate
    /// the window all that time.
    private static let pulseCount = 12
    private static let pulseInterval: Duration = .milliseconds(800)

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let badge: RemoteDeviceBadge
    let status: RemoteDeviceHeaderStatus
    let fontSize: CGFloat
    /// The header's text colour, which "@" and a grey name are shades of.
    let textColor: Color

    @State private var pulseIsDim = false

    var body: some View {
        HStack(spacing: Self.spacing) {
            Text("@")
                .font(.system(size: fontSize, weight: .regular))
                .foregroundStyle(textColor.opacity(0.45))
                .fixedSize()
            Text(badge.name)
                .font(.system(size: fontSize, weight: .medium))
                .foregroundStyle(nameColor)
                .opacity(nameOpacity)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: min(Self.nameWidth(badge.name, fontSize: fontSize), Self.minimumNameWidth), alignment: .leading)
                .background(RemoteDeviceHeaderAnchor())
            if case .needsYou = status {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: fontSize - 4, weight: .semibold))
                    .foregroundStyle(.orange)
                    .frame(width: Self.warningWidth)
            }
        }
        .accessibilityHidden(true)
        .task(id: status == .reconnecting && !reduceMotion) {
            guard status == .reconnecting, !reduceMotion else {
                pulseIsDim = false
                return
            }
            for _ in 0..<Self.pulseCount {
                withAnimation(.easeInOut(duration: 0.8)) { pulseIsDim.toggle() }
                do { try await Task.sleep(for: Self.pulseInterval) } catch { return }
            }
            withAnimation(.easeInOut(duration: 0.8)) { pulseIsDim = false }
        }
    }

    private var nameColor: Color {
        if case .needsYou = status { return textColor.opacity(0.55) }
        return badge.color.color(for: colorScheme)
    }

    private var nameOpacity: Double {
        guard status == .reconnecting else { return 1 }
        return pulseIsDim ? 0.3 : 0.5
    }

    /// Its width, for the header's own measuring.
    static func width(of badge: RemoteDeviceBadge, status: RemoteDeviceHeaderStatus, fontSize: CGFloat) -> CGFloat {
        let at = ceil(("@" as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .regular)]).width)
        var width = at + spacing + nameWidth(badge.name, fontSize: fontSize)
        if case .needsYou = status { width += spacing + warningWidth }
        return width
    }

    private static func nameWidth(_ name: String, fontSize: CGFloat) -> CGFloat {
        ceil((name as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: fontSize, weight: .medium)]).width)
    }
}

/// Marks a device window's "@ <Mac>" for tests that look for it.
private struct RemoteDeviceHeaderAnchor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.identifier = .remoteDeviceHeaderAnchor
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {}
}

extension NSUserInterfaceItemIdentifier {
    static let remoteDeviceHeaderAnchor = NSUserInterfaceItemIdentifier("Cherry.RemoteDeviceHeaderAnchor")
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
