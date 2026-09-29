import AppKit
import SwiftUI

/// The Omni bar's design knobs (Prototype › Show Omni Bar Playground),
/// defaulting to design D: 580 pt wide, 38 pt rows, a glass surface.
enum CommandPaletteDesign {
    static let usesGlassKey = "omniBar.design.usesGlass"
    static let cornerRadiusKey = "omniBar.design.cornerRadius"
    static let panelWidthKey = "omniBar.design.panelWidth"
    static let scrimOpacityKey = "omniBar.design.scrimOpacity"
    static let animatesEntranceKey = "omniBar.design.animatesEntrance"
    static let rowHeightKey = "omniBar.design.rowHeight"
    static let highlightsMatchesKey = "omniBar.design.highlightsMatches"

    static let defaultUsesGlass = true
    static let defaultCornerRadius = 14.0
    static let defaultPanelWidth = 580.0
    static let defaultScrimOpacity = 0.12
    static let defaultAnimatesEntrance = true
    static let defaultRowHeight = 38.0
    static let defaultHighlightsMatches = true

    static func reset() {
        let defaults = UserDefaults.standard
        defaults.set(defaultUsesGlass, forKey: usesGlassKey)
        defaults.set(defaultCornerRadius, forKey: cornerRadiusKey)
        defaults.set(defaultPanelWidth, forKey: panelWidthKey)
        defaults.set(defaultScrimOpacity, forKey: scrimOpacityKey)
        defaults.set(defaultAnimatesEntrance, forKey: animatesEntranceKey)
        defaults.set(defaultRowHeight, forKey: rowHeightKey)
        defaults.set(defaultHighlightsMatches, forKey: highlightsMatchesKey)
    }
}

struct CommandPalettePlaygroundOverlay: View {
    @ObservedObject var chromeState: ProjectWindowChromeState
    @Binding var isPresented: Bool

    @AppStorage(CommandPaletteDesign.usesGlassKey) private var usesGlass = CommandPaletteDesign.defaultUsesGlass
    @AppStorage(CommandPaletteDesign.cornerRadiusKey) private var cornerRadius = CommandPaletteDesign.defaultCornerRadius
    @AppStorage(CommandPaletteDesign.panelWidthKey) private var panelWidth = CommandPaletteDesign.defaultPanelWidth
    @AppStorage(CommandPaletteDesign.scrimOpacityKey) private var scrimOpacity = CommandPaletteDesign.defaultScrimOpacity
    @AppStorage(CommandPaletteDesign.animatesEntranceKey) private var animatesEntrance = CommandPaletteDesign.defaultAnimatesEntrance
    @AppStorage(CommandPaletteDesign.rowHeightKey) private var rowHeight = CommandPaletteDesign.defaultRowHeight
    @AppStorage(CommandPaletteDesign.highlightsMatchesKey) private var highlightsMatches = CommandPaletteDesign.defaultHighlightsMatches

    var body: some View {
        panel
            .padding(.top, 52)
            .padding(.trailing, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .transition(.opacity)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            sectionTitle("Panel")
            Toggle("Liquid Glass", isOn: $usesGlass)
            slider("Corner Radius", value: $cornerRadius, in: 8...28, format: "%.0f")
            slider("Width", value: $panelWidth, in: 520...700, format: "%.0f")
            slider("Scrim", value: $scrimOpacity, in: 0...0.35, format: "%.2f")
            Toggle("Animate Entrance", isOn: $animatesEntrance)

            sectionTitle("Rows")
            slider("Row Height", value: $rowHeight, in: 32...48, format: "%.0f")
            Toggle("Bold Matches", isOn: $highlightsMatches)
        }
        .font(.system(size: 12))
        .controlSize(.small)
        .padding(14)
        .frame(width: 330)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 18, y: 10)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Omni Bar")
                .font(.system(size: 14, weight: .semibold))

            Spacer()

            Button {
                if !chromeState.isOmniBarPresented { chromeState.toggleOmniBar() }
            } label: {
                Image(systemName: "command")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Open the Omni bar (⌘P)")

            Button(action: CommandPaletteDesign.reset) {
                Image(systemName: "arrow.counterclockwise")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Reset to design D")

            Button {
                isPresented = false
            } label: {
                Image(systemName: "xmark")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Close")
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .padding(.top, 2)
    }

    private func slider(
        _ title: String,
        value: Binding<Double>,
        in range: ClosedRange<Double>,
        format: String
    ) -> some View {
        HStack(spacing: 8) {
            Text(title)
                .frame(width: 92, alignment: .leading)
            Slider(value: value, in: range)
            Text(String(format: format, value.wrappedValue))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }
}
