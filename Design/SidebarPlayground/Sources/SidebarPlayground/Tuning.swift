import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct Tuning: Codable, Equatable {
    var version = 1
    var sidebarWidth = 280.0
    var leftInset = 12.0
    var rowHeight = 32.0
    var rowGap = 1.0
    var folderGap = 8.0
    var iconGap = 7.0
    var iconSize = 16.0
    var iconSlot = 20.0
    var textSize = 13.0
    var headerSize = 13.0
    var textWeight = 0.0
    var selectionInset = 0.0
    var selectionRadius = 0.0
    var hoverOpacity = 0.06
    var selectedOpacity = 0.10
    var sidebarColor = "#2E2E2E"
    var contentColor = "#202020"
    var textColor = "#D0D0D0"
    var highlightColor = "#FFFFFF"
    var folderIcons = false
    var chevrons = false
    var subtitles = false
    var showTools = true
    var showShortcuts = false
    var templateIcons = true
    var subAgentIndent = 20.0
    var subAgentGap = 4.0
    var treeGuideOpacity = 0.18
    var treeGuideOffset = 0.0
    var loadingIndicators = true
    var treeGuides = true
    var agentStatus = true
    var iconGuides = false

    init() {}
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        version = try values.decodeIfPresent(Int.self, forKey: .version) ?? 1
        sidebarWidth = try values.decodeIfPresent(Double.self, forKey: .sidebarWidth) ?? 280.0
        leftInset = try values.decodeIfPresent(Double.self, forKey: .leftInset) ?? 12.0
        rowHeight = try values.decodeIfPresent(Double.self, forKey: .rowHeight) ?? 32.0
        rowGap = try values.decodeIfPresent(Double.self, forKey: .rowGap) ?? 1.0
        folderGap = try values.decodeIfPresent(Double.self, forKey: .folderGap) ?? 8.0
        iconGap = try values.decodeIfPresent(Double.self, forKey: .iconGap) ?? 7.0
        iconSize = try values.decodeIfPresent(Double.self, forKey: .iconSize) ?? 16.0
        iconSlot = try values.decodeIfPresent(Double.self, forKey: .iconSlot) ?? 20.0
        textSize = try values.decodeIfPresent(Double.self, forKey: .textSize) ?? 13.0
        headerSize = try values.decodeIfPresent(Double.self, forKey: .headerSize) ?? 13.0
        textWeight = try values.decodeIfPresent(Double.self, forKey: .textWeight) ?? 0.0
        selectionInset = try values.decodeIfPresent(Double.self, forKey: .selectionInset) ?? 0.0
        selectionRadius = try values.decodeIfPresent(Double.self, forKey: .selectionRadius) ?? 0.0
        hoverOpacity = try values.decodeIfPresent(Double.self, forKey: .hoverOpacity) ?? 0.06
        selectedOpacity = try values.decodeIfPresent(Double.self, forKey: .selectedOpacity) ?? 0.10
        sidebarColor = try values.decodeIfPresent(String.self, forKey: .sidebarColor) ?? "#2E2E2E"
        contentColor = try values.decodeIfPresent(String.self, forKey: .contentColor) ?? "#202020"
        textColor = try values.decodeIfPresent(String.self, forKey: .textColor) ?? "#D0D0D0"
        highlightColor = try values.decodeIfPresent(String.self, forKey: .highlightColor) ?? "#FFFFFF"
        folderIcons = try values.decodeIfPresent(Bool.self, forKey: .folderIcons) ?? false
        chevrons = try values.decodeIfPresent(Bool.self, forKey: .chevrons) ?? false
        subtitles = try values.decodeIfPresent(Bool.self, forKey: .subtitles) ?? false
        showTools = try values.decodeIfPresent(Bool.self, forKey: .showTools) ?? true
        showShortcuts = try values.decodeIfPresent(Bool.self, forKey: .showShortcuts) ?? false
        templateIcons = try values.decodeIfPresent(Bool.self, forKey: .templateIcons) ?? true
        subAgentIndent = try values.decodeIfPresent(Double.self, forKey: .subAgentIndent) ?? 20.0
        subAgentGap = try values.decodeIfPresent(Double.self, forKey: .subAgentGap) ?? 4.0
        treeGuideOpacity = try values.decodeIfPresent(Double.self, forKey: .treeGuideOpacity) ?? 0.18
        treeGuideOffset = try values.decodeIfPresent(Double.self, forKey: .treeGuideOffset) ?? 0.0
        loadingIndicators = try values.decodeIfPresent(Bool.self, forKey: .loadingIndicators) ?? true
        treeGuides = try values.decodeIfPresent(Bool.self, forKey: .treeGuides) ?? true
        agentStatus = try values.decodeIfPresent(Bool.self, forKey: .agentStatus) ?? true
        iconGuides = try values.decodeIfPresent(Bool.self, forKey: .iconGuides) ?? false
    }

    static let current = Tuning()
    static var compact: Tuning {
        var value = current
        value.sidebarWidth = 244; value.rowHeight = 28
        value.leftInset = 8; value.iconSize = 14; value.iconSlot = 18
        value.folderGap = 6; value.textSize = 12
        return value
    }
    static var airy: Tuning {
        var value = current
        value.sidebarWidth = 300; value.rowHeight = 40
        value.leftInset = 16; value.folderGap = 16; value.textSize = 14
        value.selectionInset = 8; value.selectionRadius = 6
        return value
    }
    static var ranges: [WritableKeyPath<Tuning, Double>: ClosedRange<Double>] { [
        \.treeGuideOffset: -12...16, \.subAgentIndent: 12...48, \.subAgentGap: 0...16, \.treeGuideOpacity: 0...0.6,
        \.sidebarWidth: 200...380, \.leftInset: 0...40, \.rowHeight: 24...56,
        \.rowGap: 0...12, \.folderGap: 0...32, \.iconGap: 0...20,
        \.iconSize: 10...24, \.iconSlot: 12...32,
        \.textSize: 10...18, \.headerSize: 10...18, \.textWeight: 0...2,
        \.selectionInset: 0...20, \.selectionRadius: 0...16,
        \.hoverOpacity: 0...0.3, \.selectedOpacity: 0.02...0.4
    ] }
    // Offset from the parent icon's visible left edge; keep the elbow pointing right.
    var treeGuideX: Double { max(0, leftInset + min(treeGuideOffset, subAgentIndent - 4)) }

    func validated() throws -> Tuning {
        guard version == 1 else { throw TuningError.invalid("Unsupported preset version.") }
        for (key, range) in Self.ranges {
            guard self[keyPath: key].isFinite, range.contains(self[keyPath: key]) else {
                throw TuningError.invalid("A numeric setting is outside the supported range.")
            }
        }
        for hex in [sidebarColor, contentColor, textColor, highlightColor] {
            guard hex.count == 7, hex.first == "#", UInt32(hex.dropFirst(), radix: 16) != nil else {
                throw TuningError.invalid("Colors must use six-digit hex values, such as #2E2E2E.")
            }
        }
        return self
    }
    func json() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
    var swiftValues: String {
        """
        // Cherry sidebar playground — values in points.
        // Reference values for applying the design in ContentView.swift.
        let sidebarWidth: CGFloat = \(sidebarWidth)
        let leftInset: CGFloat = \(leftInset)
        let rowHeight: CGFloat = \(rowHeight)
        let rowGap: CGFloat = \(rowGap)
        let folderGap: CGFloat = \(folderGap)
        let iconGap: CGFloat = \(iconGap)
        let iconSize: CGFloat = \(iconSize)
        let iconSlot: CGFloat = \(iconSlot)
        let textSize: CGFloat = \(textSize)
        let headerSize: CGFloat = \(headerSize)
        let textWeight: Font.Weight = .\(["regular", "medium", "semibold"][Int(textWeight.rounded())])
        let selectionInset: CGFloat = \(selectionInset)
        let selectionRadius: CGFloat = \(selectionRadius)
        let hoverOpacity: Double = \(hoverOpacity)
        let selectedOpacity: Double = \(selectedOpacity)
        let sidebarColor = "\(sidebarColor)"
        let contentColor = "\(contentColor)"
        let textColor = "\(textColor)"
        let highlightColor = "\(highlightColor)"
        let folderIcons = \(folderIcons)
        let chevrons = \(chevrons)
        let subtitles = \(subtitles)
        let showTools = \(showTools)
        let showShortcuts = \(showShortcuts)
        let templateIcons = \(templateIcons)
        let subAgentIndent: CGFloat = \(subAgentIndent)
        let subAgentGap: CGFloat = \(subAgentGap)
        let treeGuideOpacity: Double = \(treeGuideOpacity)
        let treeGuideOffset: CGFloat = \(treeGuideOffset)
        let loadingIndicators = \(loadingIndicators)
        let treeGuides = \(treeGuides)
        let agentStatus = \(agentStatus)
        let iconGuides = \(iconGuides)
        """
    }
}

enum TuningError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { message } else { nil } }
}

struct SavedPreset: Codable, Identifiable {
    var id = UUID()
    var name: String
    var tuning: Tuning
}

@MainActor
final class PlaygroundStore: ObservableObject {
    @Published var tuning: Tuning { didSet { persist() } }
    @Published var presets: [SavedPreset] { didSet { persist() } }
    @Published var message = "Changes save automatically."
    @Published var error: String?
    @Published var comparing = false
    var displayed: Tuning { comparing ? .current : tuning }
    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        tuning = defaults.data(forKey: "playground.tuning").flatMap {
            try? JSONDecoder().decode(Tuning.self, from: $0).validated()
        } ?? .current
        presets = defaults.data(forKey: "playground.presets").flatMap {
            try? JSONDecoder().decode([SavedPreset].self, from: $0)
        }?.filter { (try? $0.tuning.validated()) != nil } ?? []
    }
    func persist() {
        if let data = try? tuning.json() { defaults.set(data, forKey: "playground.tuning") }
        if let data = try? JSONEncoder().encode(presets) { defaults.set(data, forKey: "playground.presets") }
    }
    func apply(_ value: Tuning) { comparing = false; tuning = value }
    func savePreset(_ rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        if let index = presets.firstIndex(where: { $0.name == name }) { presets[index].tuning = tuning }
        else { presets.append(SavedPreset(name: name, tuning: tuning)) }
        message = "Saved \(name)."
    }
    func copySwift() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(tuning.swiftValues, forType: .string)
        message = "Swift values copied."
    }
    func exportJSON() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "cherry-sidebar.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try tuning.json().write(to: url, options: .atomic); message = "Exported \(url.lastPathComponent)." }
        catch { self.error = error.localizedDescription }
    }
    func importJSON() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 < 1_000_000 else {
                throw TuningError.invalid("This preset is too large.")
            }
            apply(try JSONDecoder().decode(Tuning.self, from: Data(contentsOf: url)).validated())
            message = "Imported \(url.lastPathComponent)."
        } catch { self.error = error.localizedDescription }
    }
}

extension Color {
    init(hex: String) {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        self.init(.sRGB, red: Double((value >> 16) & 255) / 255,
                  green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, opacity: 1)
    }
    var hex: String {
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return "#000000" }
        return String(format: "#%02X%02X%02X", Int((rgb.redComponent * 255).rounded()),
                      Int((rgb.greenComponent * 255).rounded()), Int((rgb.blueComponent * 255).rounded()))
    }
}
