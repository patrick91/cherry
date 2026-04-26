import Foundation
import GhosttyTerminal

extension Notification.Name {
    static let terminalSettingsDidChange = Notification.Name("Cherry.terminalSettingsDidChange")
}

@MainActor
final class TerminalSettings: ObservableObject {
    static let shared = TerminalSettings()

    @Published var fontSize: Double {
        didSet { save(fontSize, forKey: Keys.fontSize) }
    }

    @Published var cursorBlink: Bool {
        didSet { save(cursorBlink, forKey: Keys.cursorBlink) }
    }

    @Published var minimumContrast: Double {
        didSet { save(minimumContrast, forKey: Keys.minimumContrast) }
    }

    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        fontSize = defaults.object(forKey: Keys.fontSize) as? Double ?? Defaults.fontSize
        cursorBlink = defaults.object(forKey: Keys.cursorBlink) as? Bool ?? Defaults.cursorBlink
        minimumContrast = defaults.object(forKey: Keys.minimumContrast) as? Double ?? Defaults.minimumContrast
    }

    func resetTerminalAppearance() {
        fontSize = Defaults.fontSize
        cursorBlink = Defaults.cursorBlink
        minimumContrast = Defaults.minimumContrast
    }

    func ghosttyConfiguration() -> TerminalConfiguration {
        TerminalConfiguration { builder in
            builder.withFontFamily("SF Mono")
            builder.withFontSize(Float(fontSize))
            builder.withCursorStyle(.block)
            builder.withCursorStyleBlink(cursorBlink)
            builder.withBackground("#121018")
            builder.withForeground("#DCE4EC")
            builder.withCursorColor("#92E6A7")
            builder.withSelectionBackground("#363C4D")
            builder.withMinimumContrast(minimumContrast)
            builder.withWindowPaddingX(8)
            builder.withWindowPaddingY(14)
            builder.withPalette(0, color: "#65717D")
            builder.withPalette(1, color: "#EA5E5E")
            builder.withPalette(2, color: "#94DE8A")
            builder.withPalette(3, color: "#E8C76E")
            builder.withPalette(4, color: "#7CB7F7")
            builder.withPalette(5, color: "#D696F2")
            builder.withPalette(6, color: "#6ED1DB")
            builder.withPalette(7, color: "#CAD1DB")
            builder.withPalette(8, color: "#8995A1")
            builder.withPalette(9, color: "#FA8280")
            builder.withPalette(10, color: "#ABF29E")
            builder.withPalette(11, color: "#FADE85")
            builder.withPalette(12, color: "#9FD0FF")
            builder.withPalette(13, color: "#EBB0FC")
            builder.withPalette(14, color: "#91EEF2")
            builder.withPalette(15, color: "#F0F5FA")
        }
    }

    private func save(_ value: Double, forKey key: String) {
        defaults.set(value, forKey: key)
        notifyChanged()
    }

    private func save(_ value: Bool, forKey key: String) {
        defaults.set(value, forKey: key)
        notifyChanged()
    }

    private func notifyChanged() {
        NotificationCenter.default.post(name: .terminalSettingsDidChange, object: self)
    }

    private enum Defaults {
        static let fontSize = 14.0
        static let cursorBlink = true
        static let minimumContrast = 1.15
    }

    private enum Keys {
        static let fontSize = "terminal.fontSize"
        static let cursorBlink = "terminal.cursorBlink"
        static let minimumContrast = "terminal.minimumContrast"
    }
}
