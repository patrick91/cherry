import AppKit
import SwiftUI

/// Settings › Interface: the app's color scheme and the sidebar's look,
/// with the colors Cherry derived for the sidebar while ⌥ is held.
struct InterfaceSettingsPage: View, SettingsPageContent {
    /// What Reset Interface… resets: this page only.
    static let resetSettings = TerminalSettings.Setting.interfacePage

    @ObservedObject private var settings: TerminalSettings
    @StateObject private var optionKey = OptionKeyObserver()

    init(settings: TerminalSettings = .shared) {
        self.settings = settings
    }

    var body: some View {
        SettingsPageScroll(SettingsPage.interface.title) {
            SettingsSection("Appearance", caption: Self.colorSchemeHelp) {
                colorSchemePicker
            }

            SettingsSection("Sidebar") {
                SettingsItem(
                    id: .interfacePaths,
                    TerminalSettings.Setting.sidebarTerminalPathDisplayMode.title,
                    help: Self.pathsHelp,
                    source: .terminal(.sidebarTerminalPathDisplayMode, in: settings)
                ) {
                    Picker(
                        TerminalSettings.Setting.sidebarTerminalPathDisplayMode.title,
                        selection: $settings.sidebarTerminalPathDisplayMode
                    ) {
                        ForEach(SidebarTerminalPathDisplayMode.allCases) { mode in
                            Text(mode.label)
                                .tag(mode)
                        }
                    }
                    .settingsMenuPicker()
                    .disabled(!settings.source(of: .sidebarTerminalPathDisplayMode).isEditable)
                }

                SettingsItem(
                    id: .interfaceProjectColors,
                    TerminalSettings.Setting.projectColorDisplayMode.title,
                    help: Self.projectColorsHelp,
                    source: .terminal(.projectColorDisplayMode, in: settings)
                ) {
                    ProjectColorModeControl(selection: $settings.projectColorDisplayMode)
                        .disabled(!settings.source(of: .projectColorDisplayMode).isEditable)
                }

                SettingsItem(
                    id: .interfaceSidebarContrast,
                    TerminalSettings.Setting.sidebarBackgroundDepth.title,
                    help: Self.sidebarContrastHelp,
                    source: .terminal(.sidebarBackgroundDepth, in: settings)
                ) {
                    SettingsSliderControl(
                        TerminalSettings.Setting.sidebarBackgroundDepth.title,
                        value: $settings.sidebarBackgroundDepth,
                        in: 0...0.24,
                        step: 0.01,
                        valueText: settings.valueText(.sidebarBackgroundDepth)
                    )
                    .disabled(!settings.source(of: .sidebarBackgroundDepth).isEditable)
                }

                if optionKey.isOptionDown {
                    SettingsSubItem {
                        SidebarThemeDebugPanel(settings: settings)
                    }
                }
            }

            SettingsPageFooter(caption: "Resets this page only.") {
                SettingsPageResetButton("Reset Interface…", settings: Self.resetSettings, in: settings)
            }
        }
    }

    /// Color scheme's Auto, Light and Dark thumbnails. A launch argument
    /// that sets it makes it read-only: the thumbnails dim and take no
    /// clicks, while its badge still opens.
    private var colorSchemePicker: some View {
        let isEditable = settings.source(of: .appearance).isEditable
        return SettingsVisualPicker(
            id: .interfaceColorScheme,
            TerminalSettings.Setting.appearance.title,
            selection: Binding(
                get: { settings.appearance },
                set: { appearance in
                    if isEditable { settings.appearance = appearance }
                }
            ),
            options: CherryAppearancePreference.allCases.map { .init($0, caption: $0.label) },
            source: .terminal(.appearance, in: settings)
        ) { appearance in
            ColorSchemeThumbnail(appearance: appearance)
                .opacity(isEditable ? 1 : 0.5)
        }
    }

    private static let colorSchemeHelp = "Auto follows macOS."
    private static let pathsHelp = "How folder names appear in the sidebar's tab rows."
    private static let projectColorsHelp = "Uses each project's color in its windows and sidebar."
    private static let sidebarContrastHelp = "How far the sidebar's background is from the terminal's."

    static func searchRows(in context: SettingsSearchContext) -> [SettingsSearchRow] {
        let terminal = context.terminal
        return [
            SettingsSearchRow(
                id: .interfaceColorScheme,
                route: .page(.interface),
                section: "Appearance",
                title: TerminalSettings.Setting.appearance.title,
                help: colorSchemeHelp,
                keywords: ["dark mode", "light mode", "theme"],
                value: terminal.valueText(.appearance)
            ),
            SettingsSearchRow(
                id: .interfacePaths,
                route: .page(.interface),
                section: "Sidebar",
                title: TerminalSettings.Setting.sidebarTerminalPathDisplayMode.title,
                help: pathsHelp,
                keywords: ["path", "folder names", "labels", "initials"],
                value: terminal.valueText(.sidebarTerminalPathDisplayMode)
            ),
            SettingsSearchRow(
                id: .interfaceProjectColors,
                route: .page(.interface),
                section: "Sidebar",
                title: TerminalSettings.Setting.projectColorDisplayMode.title,
                help: projectColorsHelp,
                keywords: ["color", "colour", "tint", "accent", "identity"],
                value: terminal.valueText(.projectColorDisplayMode)
            ),
            SettingsSearchRow(
                id: .interfaceSidebarContrast,
                route: .page(.interface),
                section: "Sidebar",
                title: TerminalSettings.Setting.sidebarBackgroundDepth.title,
                help: sidebarContrastHelp,
                keywords: ["sidebar", "background", "depth"],
                value: terminal.valueText(.sidebarBackgroundDepth)
            ),
        ]
    }
}

extension SettingsRowID {
    static let interfaceColorScheme: Self = "interface.colorScheme"
    static let interfacePaths: Self = "interface.paths"
    static let interfaceProjectColors: Self = "interface.projectColors"
    static let interfaceSidebarContrast: Self = "interface.sidebarContrast"
}

// MARK: - Color scheme thumbnails

/// A Color scheme thumbnail: a window with its
/// sidebar on a desktop, light or dark; Auto is the two, split across.
private struct ColorSchemeThumbnail: View {
    let appearance: CherryAppearancePreference

    var body: some View {
        switch appearance {
        case .light:
            WindowSketch(.light)
        case .dark:
            WindowSketch(.dark)
        case .system:
            WindowSketch(.light)
                .overlay {
                    WindowSketch(.dark)
                        .mask { DiagonalHalf() }
                }
        }
    }
}

/// A desktop with a window and its sidebar, in light or dark colors.
private struct WindowSketch: View {
    let colorScheme: ColorScheme

    init(_ colorScheme: ColorScheme) {
        self.colorScheme = colorScheme
    }

    var body: some View {
        let isDark = colorScheme == .dark
        let window = RoundedRectangle(cornerRadius: 6, style: .continuous)
        SettingsDesign.Colors.hex(isDark ? "#33405A" : "#9DB0C9")
            .overlay {
                window
                    .fill(SettingsDesign.Colors.hex(isDark ? "#1F1F22" : "#F5F5F7"))
                    .overlay(alignment: .leading) {
                        Rectangle()
                            .fill(SettingsDesign.Colors.hex(isDark ? "#2C2C30" : "#E3E3E8"))
                            .frame(width: 20)
                    }
                    .clipShape(window)
                    .shadow(color: .black.opacity(isDark ? 0.4 : 0.25), radius: 1.5, y: 1)
                    .padding(EdgeInsets(top: 11, leading: 13, bottom: 9, trailing: 13))
            }
    }
}

/// The part of a rectangle past a line through its middle, tilted 120°:
/// the lower right, dark half of Auto.
private struct DiagonalHalf: Shape {
    func path(in rect: CGRect) -> Path {
        // 120° (clockwise from up) points right and a little down; the
        // split runs across it.
        let along = CGPoint(x: cos(Double.pi / 6), y: sin(Double.pi / 6))
        let across = CGPoint(x: -along.y, y: along.x)
        let reach = rect.width + rect.height
        let middle = CGPoint(x: rect.midX, y: rect.midY)
        func point(_ acrossBy: Double, _ alongBy: Double) -> CGPoint {
            CGPoint(
                x: middle.x + across.x * acrossBy + along.x * alongBy,
                y: middle.y + across.y * acrossBy + along.y * alongBy
            )
        }
        var path = Path()
        path.move(to: point(reach, 0))
        path.addLine(to: point(reach, reach))
        path.addLine(to: point(-reach, reach))
        path.addLine(to: point(-reach, 0))
        path.closeSubpath()
        return path
    }
}

// MARK: - Project colors

/// Project colors' segmented control: Off, Accent with a dot of a
/// project's color, and Tinted with the dot in a ring of its tint. An
/// `NSSegmentedControl`, which draws a segment's image before its text and
/// keeps the dots' colors (they are not template images).
private struct ProjectColorModeControl: NSViewRepresentable {
    @Binding var selection: ProjectColorDisplayMode

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let modes = ProjectColorDisplayMode.allCases
        let control = NSSegmentedControl(
            labels: modes.map(\.label),
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.choose(_:))
        )
        for (index, mode) in modes.enumerated() {
            guard let dot = Self.dot(for: mode) else { continue }
            control.setImage(dot, forSegment: index)
            control.setImageScaling(.scaleNone, forSegment: index)
        }
        control.setAccessibilityLabel(TerminalSettings.Setting.projectColorDisplayMode.title)
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        let index = ProjectColorDisplayMode.allCases.firstIndex(of: selection) ?? 0
        if control.selectedSegment != index { control.selectedSegment = index }
        if control.isEnabled != context.environment.isEnabled { control.isEnabled = context.environment.isEnabled }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView control: NSSegmentedControl, context: Context) -> CGSize? {
        control.intrinsicContentSize
    }

    /// Accent's dot (Blue, standing for a project's color), or
    /// Tinted's, in a ring of its tint; none for Off.
    private static func dot(for mode: ProjectColorDisplayMode) -> NSImage? {
        guard mode != .off, let color = NSColor(hexRGB: ProjectIdentityColor.blue.hexRGB) else { return nil }
        let dotSide: CGFloat = 8
        let side: CGFloat = mode == .tinted ? 12 : dotSide
        let image = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            if side > dotSide {
                color.withAlphaComponent(0.35).setFill()
                NSBezierPath(ovalIn: rect).fill()
            }
            color.setFill()
            let inset = (side - dotSide) / 2
            NSBezierPath(ovalIn: rect.insetBy(dx: inset, dy: inset)).fill()
            return true
        }
        image.isTemplate = false
        return image
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<ProjectColorDisplayMode>

        init(selection: Binding<ProjectColorDisplayMode>) {
            self.selection = selection
        }

        @objc func choose(_ sender: NSSegmentedControl) {
            let modes = ProjectColorDisplayMode.allCases
            guard modes.indices.contains(sender.selectedSegment) else { return }
            let mode = modes[sender.selectedSegment]
            guard mode != selection.wrappedValue else { return }
            selection.wrappedValue = mode
        }
    }
}

// MARK: - ⌥ color check

/// What the sidebar's colors come to with the theme in use:
/// the terminal's background, the sidebar's and the selection's, and how
/// far apart the first two are. Shown while ⌥ is held.
private struct SidebarThemeDebugPanel: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject var settings: TerminalSettings

    private var sample: SidebarThemeSample {
        SidebarThemeSample(
            themeColors: settings.ghosttyThemeColors(for: colorScheme),
            fallbackColorScheme: colorScheme,
            sidebarBackgroundDepth: settings.sidebarBackgroundDepth
        )
    }

    var body: some View {
        let sample = sample

        Text("Shown while ⌥ is held: the colors Cherry derived.")
            .font(SettingsDesign.Fonts.help)
            .foregroundStyle(.secondary)

        HStack(spacing: 14) {
            SidebarColorDebugSwatch(title: "Terminal", color: sample.background)
            SidebarColorDebugSwatch(title: "Sidebar", color: sample.sidebarBackground)

            if let selectionBackground = sample.selectionBackground {
                SidebarColorDebugSwatch(title: "Selection", color: selectionBackground)
            }

            Text("Luma delta \(Self.luminanceDelta(for: sample))")
                .font(SettingsDesign.Fonts.mono)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }

    private static func luminanceDelta(for sample: SidebarThemeSample) -> String {
        let delta = abs(sample.background.relativeLuminance - sample.sidebarBackground.relativeLuminance)
        return Double(delta).formatted(.number.precision(.fractionLength(3)))
    }
}

/// One color of the ⌥ check: a dot, its name and its hex value.
private struct SidebarColorDebugSwatch: View {
    let title: String
    let color: NSColor

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Color(nsColor: color))
                .frame(width: 10, height: 10)
                .overlay {
                    Circle()
                        .strokeBorder(SettingsDesign.Colors.fill3, lineWidth: 1)
                }

            Text(title)
                .font(SettingsDesign.Fonts.help)
                .foregroundStyle(.secondary)
                .lineLimit(1)

            Text(color.hexRGBString)
                .font(SettingsDesign.Fonts.mono)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}
