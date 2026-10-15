import Foundation

/// Where a setting's value comes from, as its row's badge says.
/// The top source wins. App settings: This run only, then Ghostty config,
/// then Set here, then Cherry's default. Project values: this Mac
/// (Overrides cherry.toml or This Mac only), then cherry.toml, then the
/// default. A value equal to its default shows no badge.
enum SettingSource: Equatable, Sendable {
    /// Nobody changed it: no badge.
    case cherryDefault
    /// Changed in Settings, or by a question's "Don't ask again".
    case setHere
    /// A launch argument sets it until Cherry quits (`-sessions.onQuit keep`
    /// in scripted runs), so the row is read-only. `applied` is false when
    /// the argument is none of the setting's values (`-terminal.fontSize 20`
    /// is the string "20"): it still hides the stored value, and the default
    /// is in use.
    case launchArgument(applied: Bool)
    /// A line of the user's Ghostty config sets it (`line` from 1), so the
    /// row is read-only: Edit in Ghostty Config. Cherry never writes the
    /// user's Ghostty files.
    case ghosttyConfig(file: URL, line: Int?)
    /// The project's cherry.toml sets it, for everyone who opens the folder.
    case projectFile
    /// This Mac's value replaces the one the project's cherry.toml sets.
    case overridesProjectFile
    /// A project value only this Mac has: cherry.toml says nothing about it.
    case thisMacOnly

    init(_ project: ProjectValueSource) {
        switch project {
        case .none: self = .cherryDefault
        case .projectFile: self = .projectFile
        case .overridesProjectFile: self = .overridesProjectFile
        case .thisMacOnly: self = .thisMacOnly
        }
    }

    /// The badge's words; nil for none.
    var badgeText: String? {
        switch self {
        case .cherryDefault: nil
        case .setHere: "Set here"
        case .launchArgument: "This run only"
        case .ghosttyConfig: "Ghostty config"
        case .projectFile: "cherry.toml"
        case .overridesProjectFile: "Overrides cherry.toml"
        case .thisMacOnly: "This Mac only"
        }
    }

    /// Whether the row's control can change the value: not while a launch
    /// argument or the user's Ghostty config sets it.
    var isEditable: Bool {
        switch self {
        case .launchArgument, .ghosttyConfig: false
        case .cherryDefault, .setHere, .projectFile, .overridesProjectFile, .thisMacOnly: true
        }
    }

    /// Whether the row offers ↺: Set here goes back to the
    /// default, Overrides cherry.toml back to the file's value.
    var offersRowReset: Bool {
        self == .setHere || self == .overridesProjectFile
    }

    /// What VoiceOver reads for the badge, the badge's words with the
    /// default spelled out: "Source: Set here. Default: 14 points."
    func accessibilityLabel(defaultValue: String?) -> String {
        var label = "Source: \(badgeText ?? "Cherry default")."
        if let defaultValue, !defaultValue.isEmpty {
            label += " Default: \(Self.spoken(defaultValue))."
        }
        return label
    }

    /// The source of a value stored under `key` that no Ghostty config or
    /// project sets (Wake idle agents, pre-release builds): a launch
    /// argument wins, then a stored value that is one of the setting's
    /// values (`parses`) and not its default; else the default.
    /// `isDefault` gets the stored value.
    static func stored(
        key: String,
        defaults: UserDefaults,
        launchArguments: [String: Any],
        parses: (Any) -> Bool = { _ in true },
        isDefault: (Any) -> Bool
    ) -> SettingSource {
        if let argument = launchArguments[key] {
            return .launchArgument(applied: parses(argument))
        }
        guard let stored = defaults.object(forKey: key), parses(stored), !isDefault(stored) else {
            return .cherryDefault
        }
        return .setHere
    }

    /// This run's launch arguments (`-key value`) as `defaults` sees them,
    /// by key: those of the argument domain for `.standard`, which searches
    /// it first, and none for any other store (a test's suite).
    static func launchArguments(for defaults: UserDefaults) -> [String: Any] {
        guard defaults === UserDefaults.standard else { return [:] }
        return UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    }

    /// A value's units as VoiceOver should say them: "14 pt" is "14 points".
    private static func spoken(_ value: String) -> String {
        for (unit, word) in [(" pt", " points"), (" %", " percent"), ("×", " times")] where value.hasSuffix(unit) {
            return String(value.dropLast(unit.count)) + word
        }
        return value
    }
}

/// A value a page's Reset… puts back: its row's title, its value now and
/// its default.
struct SettingsChange: Equatable, Sendable {
    var title: String
    var from: String
    var to: String

    /// "Font size 16 pt → 14 pt".
    var text: String {
        "\(title) \(from) → \(to)"
    }
}

extension SettingSource {
    /// A switch's value as its row, its badge, search and Reset… say it:
    /// "On", "Off".
    static func onOff(_ isOn: Bool) -> String {
        isOn ? "On" : "Off"
    }
}

/// The question a page's Reset… asks first. Its buttons are
/// Reset, the default, and Cancel; the page's Reset… is off while there are
/// no changes.
enum SettingsPageReset {
    /// "Reset 3 settings?" / "Font size 16 pt → 14 pt · Dark Mode theme
    /// Dracula → Afterglow · Project colors Tinted → Accent." On a page
    /// where the user's Ghostty config can set values, it adds that those
    /// stay.
    static func confirmation(
        for changes: [SettingsChange],
        mentionsGhosttyConfig: Bool
    ) -> (title: String, message: String) {
        let title = changes.count == 1 ? "Reset 1 setting?" : "Reset \(changes.count) settings?"
        var sentences: [String] = []
        if !changes.isEmpty {
            sentences.append(changes.map(\.text).joined(separator: " · ") + ".")
        }
        if mentionsGhosttyConfig {
            sentences.append("Values from your Ghostty config stay.")
        }
        return (title, sentences.joined(separator: " "))
    }
}
