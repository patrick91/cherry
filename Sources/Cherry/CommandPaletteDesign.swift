import AppKit
import SwiftUI

enum CommandPaletteSelectionStyle: Int {
    case accentFill = 0
    case softTint = 1
    case flat = 2
}

enum CommandPaletteDesign {
    static let usesGlassKey = "commandPalette.design.usesGlass"
    static let cornerRadiusKey = "commandPalette.design.cornerRadius"
    static let panelWidthKey = "commandPalette.design.panelWidth"
    static let scrimOpacityKey = "commandPalette.design.scrimOpacity"
    static let animatesEntranceKey = "commandPalette.design.animatesEntrance"
    static let usesCompactRowsKey = "commandPalette.design.usesCompactRows"
    static let rowHeightKey = "commandPalette.design.rowHeight"
    static let selectionStyleKey = "commandPalette.design.selectionStyle"
    static let usesIconTilesKey = "commandPalette.design.usesIconTiles"
    static let highlightsMatchesKey = "commandPalette.design.highlightsMatches"
    static let showsSectionHeadersKey = "commandPalette.design.showsSectionHeaders"
    static let showsKindLabelsKey = "commandPalette.design.showsKindLabels"
    static let showsFooterKey = "commandPalette.design.showsFooter"

    static let defaultUsesGlass = true
    static let defaultCornerRadius = 18.0
    static let defaultPanelWidth = 520.0
    static let defaultScrimOpacity = 0.17
    static let defaultAnimatesEntrance = true
    static let defaultUsesCompactRows = false
    static let defaultRowHeight = 50.0
    static let defaultSelectionStyle = CommandPaletteSelectionStyle.softTint.rawValue
    static let defaultUsesIconTiles = false
    static let defaultHighlightsMatches = true
    static let defaultShowsSectionHeaders = false
    static let defaultShowsKindLabels = false
    static let defaultShowsFooter = false

    static func reset() {
        let defaults = UserDefaults.standard
        defaults.set(defaultUsesGlass, forKey: usesGlassKey)
        defaults.set(defaultCornerRadius, forKey: cornerRadiusKey)
        defaults.set(defaultPanelWidth, forKey: panelWidthKey)
        defaults.set(defaultScrimOpacity, forKey: scrimOpacityKey)
        defaults.set(defaultAnimatesEntrance, forKey: animatesEntranceKey)
        defaults.set(defaultUsesCompactRows, forKey: usesCompactRowsKey)
        defaults.set(defaultRowHeight, forKey: rowHeightKey)
        defaults.set(defaultSelectionStyle, forKey: selectionStyleKey)
        defaults.set(defaultUsesIconTiles, forKey: usesIconTilesKey)
        defaults.set(defaultHighlightsMatches, forKey: highlightsMatchesKey)
        defaults.set(defaultShowsSectionHeaders, forKey: showsSectionHeadersKey)
        defaults.set(defaultShowsKindLabels, forKey: showsKindLabelsKey)
        defaults.set(defaultShowsFooter, forKey: showsFooterKey)
    }
}

extension CommandPaletteMatcher {
    /// Per-character subsequence match flags for `field`, or nil when the
    /// query does not fully match the field (highlighting is title-only, so
    /// items matched via subtitle simply render unhighlighted).
    static func matchFlags(query: String, in field: String) -> [Bool]? {
        let queryCharacters = query
            .filter { !$0.isWhitespace }
            .map(foldedCharacter)
        guard !queryCharacters.isEmpty else { return nil }

        let fieldCharacters = Array(field)
        var flags = [Bool](repeating: false, count: fieldCharacters.count)
        var queryIndex = 0
        for (index, character) in fieldCharacters.enumerated() where queryIndex < queryCharacters.count {
            if foldedCharacter(character) == queryCharacters[queryIndex] {
                flags[index] = true
                queryIndex += 1
            }
        }
        return queryIndex == queryCharacters.count ? flags : nil
    }

    private static func foldedCharacter(_ character: Character) -> String {
        String(character)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
    }
}

extension CommandPaletteRootItem {
    var sectionTitle: String {
        switch self {
        case .command: "Commands"
        case .openInDefaultEditor, .otherEditors: "Open In"
        case .agent: "Agents"
        case .project: "Projects"
        }
    }

    var kindLabel: String {
        switch self {
        case .command: "Command"
        case .openInDefaultEditor, .otherEditors: "Editor"
        case .agent: "Agent"
        case .project: "Project"
        }
    }

    var tileColor: Color {
        switch self {
        case .command(let command): command.tileColor
        case .openInDefaultEditor, .otherEditors: .teal
        case .agent: .purple
        case .project: .blue
        }
    }
}

extension CommandPaletteCommand {
    var tileColor: Color {
        switch self {
        case .projects, .addProject: .blue
        case .worktrees, .newWorktree, .manageWorktrees: .green
        case .removeWorktree: .gray
        case .agents, .addAgent: .purple
        case .toggleAppearance: .orange
        }
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
    @AppStorage(CommandPaletteDesign.usesCompactRowsKey) private var usesCompactRows = CommandPaletteDesign.defaultUsesCompactRows
    @AppStorage(CommandPaletteDesign.rowHeightKey) private var rowHeight = CommandPaletteDesign.defaultRowHeight
    @AppStorage(CommandPaletteDesign.selectionStyleKey) private var selectionStyle = CommandPaletteDesign.defaultSelectionStyle
    @AppStorage(CommandPaletteDesign.usesIconTilesKey) private var usesIconTiles = CommandPaletteDesign.defaultUsesIconTiles
    @AppStorage(CommandPaletteDesign.highlightsMatchesKey) private var highlightsMatches = CommandPaletteDesign.defaultHighlightsMatches
    @AppStorage(CommandPaletteDesign.showsSectionHeadersKey) private var showsSectionHeaders = CommandPaletteDesign.defaultShowsSectionHeaders
    @AppStorage(CommandPaletteDesign.showsKindLabelsKey) private var showsKindLabels = CommandPaletteDesign.defaultShowsKindLabels
    @AppStorage(CommandPaletteDesign.showsFooterKey) private var showsFooter = CommandPaletteDesign.defaultShowsFooter

    @State private var didCopyValues = false

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
            Toggle("Compact Rows", isOn: $usesCompactRows)
            slider("Row Height", value: $rowHeight, in: 36...56, format: "%.0f")
            selectionPicker
            Toggle("Icon Tiles", isOn: $usesIconTiles)
            Toggle("Highlight Matches", isOn: $highlightsMatches)

            sectionTitle("Extras")
            Toggle("Section Headers", isOn: $showsSectionHeaders)
            Toggle("Kind Labels", isOn: $showsKindLabels)
            Toggle("Footer Hints", isOn: $showsFooter)
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
            Text("Command Palette")
                .font(.system(size: 14, weight: .semibold))

            Spacer()

            Button(action: copyValues) {
                Label(didCopyValues ? "Copied" : "Copy Values", systemImage: didCopyValues ? "checkmark" : "doc.on.doc")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 11, weight: .medium))
                    .padding(.horizontal, 7)
                    .frame(height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .background {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Color.primary.opacity(0.08))
            }
            .help("Copy design values as Swift defaults")

            Button {
                chromeState.presentCommandPalette()
            } label: {
                Image(systemName: "command")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Open the command palette (⌘P)")

            Button(action: reset) {
                Image(systemName: "arrow.counterclockwise")
                    .frame(width: 24, height: 24)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("Reset to prototype defaults")

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

    private var selectionPicker: some View {
        HStack(spacing: 8) {
            Text("Selection")
            Spacer()
            Picker("", selection: $selectionStyle) {
                Text("Fill").tag(CommandPaletteSelectionStyle.accentFill.rawValue)
                Text("Tint").tag(CommandPaletteSelectionStyle.softTint.rawValue)
                Text("Flat").tag(CommandPaletteSelectionStyle.flat.rawValue)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 160)
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

    private func reset() {
        CommandPaletteDesign.reset()
    }

    private func copyValues() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copiedValuesText, forType: .string)
        didCopyValues = true

        Task { @MainActor in
            do {
                try await Task.sleep(for: .milliseconds(900))
            } catch {
                return
            }
            didCopyValues = false
        }
    }

    private var copiedValuesText: String {
        """
        static let defaultUsesGlass = \(usesGlass)
        static let defaultCornerRadius = \(String(format: "%.1f", cornerRadius))
        static let defaultPanelWidth = \(String(format: "%.1f", panelWidth))
        static let defaultScrimOpacity = \(String(format: "%.2f", scrimOpacity))
        static let defaultAnimatesEntrance = \(animatesEntrance)
        static let defaultUsesCompactRows = \(usesCompactRows)
        static let defaultRowHeight = \(String(format: "%.1f", rowHeight))
        static let defaultSelectionStyle = \(selectionStyle)
        static let defaultUsesIconTiles = \(usesIconTiles)
        static let defaultHighlightsMatches = \(highlightsMatches)
        static let defaultShowsSectionHeaders = \(showsSectionHeaders)
        static let defaultShowsKindLabels = \(showsKindLabels)
        static let defaultShowsFooter = \(showsFooter)
        """
    }
}
