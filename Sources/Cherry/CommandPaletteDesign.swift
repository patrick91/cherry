import AppKit
import SwiftUI

/// The Omni bar's design knobs (Prototype › Show Omni Bar Playground).
/// The switches have their own keys; every size is a `Knob`, read by the
/// bar through `OmniBarMetrics`.
enum CommandPaletteDesign {
    static let usesGlassKey = "omniBar.design.usesGlass"
    static let animatesEntranceKey = "omniBar.design.animatesEntrance"
    static let highlightsMatchesKey = "omniBar.design.highlightsMatches"

    static let defaultUsesGlass = true
    static let defaultAnimatesEntrance = true
    static let defaultHighlightsMatches = true

    /// A size of the bar, in points unless its format says otherwise.
    enum Knob: String, CaseIterable, Identifiable {
        // Panel
        case cornerRadius, panelWidth, scrimOpacity, topOffset
        // Search
        case searchHeight, searchPadding, searchFontSize, searchIconSize
        // List
        case listInset, listBottomPadding, maximumListHeight, headerHeight, headerFontSize
        // Rows
        case rowHeight, twoLineExtraHeight, rowPadding, rowCornerRadius, selectionOpacity
        case iconSize, iconColumnWidth, iconSpacing, titleFontSize, detailFontSize, shortcutFontSize
        // Footer
        case footerHeight, footerPadding, footerFontSize, keyCapFontSize
        // Actions (⌘K)
        case actionRowHeight, actionListWidth

        var id: String { rawValue }

        /// The panel's first four keep the keys they had before the table.
        var key: String {
            switch self {
            case .cornerRadius: "omniBar.design.cornerRadius"
            case .panelWidth: "omniBar.design.panelWidth"
            case .scrimOpacity: "omniBar.design.scrimOpacity"
            case .rowHeight: "omniBar.design.rowHeight"
            default: "omniBar.design.\(rawValue)"
            }
        }

        var section: String {
            switch self {
            case .cornerRadius, .panelWidth, .scrimOpacity, .topOffset: "Panel"
            case .searchHeight, .searchPadding, .searchFontSize, .searchIconSize: "Search"
            case .listInset, .listBottomPadding, .maximumListHeight, .headerHeight, .headerFontSize: "List"
            case .rowHeight, .twoLineExtraHeight, .rowPadding, .rowCornerRadius, .selectionOpacity,
                 .iconSize, .iconColumnWidth, .iconSpacing, .titleFontSize, .detailFontSize, .shortcutFontSize: "Rows"
            case .footerHeight, .footerPadding, .footerFontSize, .keyCapFontSize: "Footer"
            case .actionRowHeight, .actionListWidth: "Actions"
            }
        }

        var title: String {
            switch self {
            case .cornerRadius: "Corner Radius"
            case .panelWidth: "Width"
            case .scrimOpacity: "Scrim"
            case .topOffset: "Top Offset"
            case .searchHeight: "Height"
            case .searchPadding: "Side Padding"
            case .searchFontSize: "Font Size"
            case .searchIconSize: "Icon Size"
            case .listInset: "Side Inset"
            case .listBottomPadding: "Bottom Padding"
            case .maximumListHeight: "Max Height"
            case .headerHeight: "Header Height"
            case .headerFontSize: "Header Font"
            case .rowHeight: "Row Height"
            case .twoLineExtraHeight: "Two-Line Extra"
            case .rowPadding: "Side Padding"
            case .rowCornerRadius: "Corner Radius"
            case .selectionOpacity: "Selection"
            case .iconSize: "Icon Size"
            case .iconColumnWidth: "Icon Column"
            case .iconSpacing: "Icon Spacing"
            case .titleFontSize: "Title Font"
            case .detailFontSize: "Detail Font"
            case .shortcutFontSize: "Shortcut Font"
            case .footerHeight: "Height"
            case .footerPadding: "Side Padding"
            case .footerFontSize: "Font Size"
            case .keyCapFontSize: "Key Cap Font"
            case .actionRowHeight: "Row Height"
            case .actionListWidth: "Width"
            }
        }

        var defaultValue: Double {
            switch self {
            case .cornerRadius: 24
            case .panelWidth: 564
            case .scrimOpacity: 0.35
            case .topOffset: 86
            case .searchHeight: 44
            case .searchPadding: 16
            case .searchFontSize: 15
            case .searchIconSize: 13
            case .listInset: 6
            case .listBottomPadding: 6
            case .maximumListHeight: 400
            case .headerHeight: 22
            case .headerFontSize: 11
            case .rowHeight: 35
            case .twoLineExtraHeight: 10
            case .rowPadding: 10
            case .rowCornerRadius: 8
            case .selectionOpacity: 0.1
            case .iconSize: 12
            case .iconColumnWidth: 16
            case .iconSpacing: 9
            case .titleFontSize: 13
            case .detailFontSize: 11
            case .shortcutFontSize: 12
            case .footerHeight: 38
            case .footerPadding: 20
            case .footerFontSize: 11.5
            case .keyCapFontSize: 11
            case .actionRowHeight: 26
            case .actionListWidth: 240
            }
        }

        var range: ClosedRange<Double> {
            switch self {
            case .cornerRadius: 8...32
            case .panelWidth: 440...720
            case .scrimOpacity, .selectionOpacity: 0...0.4
            case .topOffset: 20...200
            case .searchHeight: 32...64
            case .searchPadding, .footerPadding: 6...32
            case .searchFontSize: 12...20
            case .searchIconSize, .iconSize: 9...18
            case .listInset, .listBottomPadding, .rowPadding: 0...20
            case .maximumListHeight: 200...640
            case .headerHeight: 16...32
            case .headerFontSize, .detailFontSize, .shortcutFontSize, .footerFontSize, .keyCapFontSize: 9...15
            case .rowHeight, .actionRowHeight: 22...48
            case .twoLineExtraHeight: 0...20
            case .rowCornerRadius: 0...16
            case .iconColumnWidth: 12...28
            case .iconSpacing: 4...16
            case .titleFontSize: 11...17
            case .footerHeight: 24...48
            case .actionListWidth: 180...320
            }
        }

        var format: String {
            switch self {
            case .scrimOpacity, .selectionOpacity: "%.2f"
            case .footerFontSize, .detailFontSize, .titleFontSize, .shortcutFontSize, .headerFontSize,
                 .keyCapFontSize, .searchFontSize, .iconSize, .searchIconSize: "%.1f"
            default: "%.0f"
            }
        }

        func value(in defaults: UserDefaults = .standard) -> Double {
            defaults.object(forKey: key) == nil ? defaultValue : defaults.double(forKey: key)
        }
    }

    static func reset() {
        let defaults = UserDefaults.standard
        defaults.set(defaultUsesGlass, forKey: usesGlassKey)
        defaults.set(defaultAnimatesEntrance, forKey: animatesEntranceKey)
        defaults.set(defaultHighlightsMatches, forKey: highlightsMatchesKey)
        for knob in Knob.allCases { defaults.set(knob.defaultValue, forKey: knob.key) }
    }
}

/// The bar's sizes as `CommandPaletteDesign.Knob`s say, read once per
/// change of the defaults (`current(in:)`), handed down the bar's views
/// in the environment.
struct OmniBarMetrics: Equatable {
    private var values: [CommandPaletteDesign.Knob: Double]

    init(values: [CommandPaletteDesign.Knob: Double] = [:]) {
        self.values = values
    }

    static func current(in defaults: UserDefaults = .standard) -> OmniBarMetrics {
        OmniBarMetrics(values: Dictionary(uniqueKeysWithValues: CommandPaletteDesign.Knob.allCases.map { ($0, $0.value(in: defaults)) }))
    }

    subscript(_ knob: CommandPaletteDesign.Knob) -> CGFloat {
        CGFloat(values[knob] ?? knob.defaultValue)
    }
}

private struct OmniBarMetricsKey: EnvironmentKey {
    static let defaultValue = OmniBarMetrics()
}

extension EnvironmentValues {
    var omniBarMetrics: OmniBarMetrics {
        get { self[OmniBarMetricsKey.self] }
        set { self[OmniBarMetricsKey.self] = newValue }
    }
}

struct CommandPalettePlaygroundOverlay: View {
    @ObservedObject var chromeState: ProjectWindowChromeState
    @Binding var isPresented: Bool

    @AppStorage(CommandPaletteDesign.usesGlassKey) private var usesGlass = CommandPaletteDesign.defaultUsesGlass
    @AppStorage(CommandPaletteDesign.animatesEntranceKey) private var animatesEntrance = CommandPaletteDesign.defaultAnimatesEntrance
    @AppStorage(CommandPaletteDesign.highlightsMatchesKey) private var highlightsMatches = CommandPaletteDesign.defaultHighlightsMatches

    private static let sections = ["Panel", "Search", "List", "Rows", "Footer", "Actions"]

    var body: some View {
        panel
            .padding(.top, 52)
            .padding(.trailing, 16)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
            .transition(.opacity)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            header
                .padding(.horizontal, 14)
                .padding(.top, 14)
            // As tall as its knobs, scrolling only when the window is shorter.
            ViewThatFits(in: .vertical) {
                knobs
                ScrollView { knobs }
                    .scrollIndicators(.automatic)
            }
        }
        .font(.system(size: 12))
        .controlSize(.small)
        .frame(width: 330)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.18), radius: 18, y: 10)
    }

    private var knobs: some View {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Self.sections, id: \.self) { section in
                        sectionTitle(section)
                        switch section {
                        case "Panel":
                            Toggle("Liquid Glass", isOn: $usesGlass)
                            Toggle("Animate Entrance", isOn: $animatesEntrance)
                        case "Rows":
                            Toggle("Bold Matches", isOn: $highlightsMatches)
                        default:
                            EmptyView()
                        }
                        ForEach(CommandPaletteDesign.Knob.allCases.filter { $0.section == section }) { knob in
                            KnobSlider(knob: knob)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.bottom, 14)
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
            .help("Reset to the defaults")

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

}

/// One knob's slider, reading and writing its default.
private struct KnobSlider: View {
    let knob: CommandPaletteDesign.Knob
    @AppStorage private var value: Double

    init(knob: CommandPaletteDesign.Knob) {
        self.knob = knob
        _value = AppStorage(wrappedValue: knob.defaultValue, knob.key)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(knob.title)
                .frame(width: 92, alignment: .leading)
            Slider(value: $value, in: knob.range)
            Text(String(format: knob.format, value))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .trailing)
        }
    }
}
