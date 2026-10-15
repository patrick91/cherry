import Foundation

/// Sparkle's automatic checks and downloads as this Mac stores them, and
/// Cherry's Get pre-release builds, read without Sparkle. Sparkle keeps
/// `SUEnableAutomaticChecks` and `SUAutomaticallyUpdate` in the app's own
/// defaults, over the values the Info.plist gives (a release's sets both on:
/// Scripts/install-local-app). Settings › Updates shows these values while
/// the updater isn't running (a build that doesn't update itself, or before
/// it starts), and its badges compare them with their defaults. It only
/// reads: the keys are written through the running updater (`AppUpdater`'s
/// setters), never here, and they stay out of `TerminalSettings`.
struct AppUpdateStoredPreferences: Equatable {
    static let automaticChecksKey = "SUEnableAutomaticChecks"
    static let automaticDownloadsKey = "SUAutomaticallyUpdate"

    /// One of Sparkle's two switches.
    struct Switch: Equatable {
        var key: String
        /// A launch argument's value, else the stored one, else the default.
        var value: Bool
        /// The Info.plist's value, else on.
        var defaultValue: Bool
        /// This run only, Set here (stored, and not the default) or Cherry's
        /// default.
        var source: SettingSource
    }

    var automaticChecks: Switch
    var automaticDownloads: Switch
    /// Get pre-release builds (`AppUpdateModel.prereleasesKey`): off unless
    /// stored on.
    var prereleases: Bool
    var prereleasesSource: SettingSource

    /// `info`: the app's Info.plist. `launchArguments`: nil reads this
    /// run's for `.standard` and none for another store
    /// (`SettingSource.launchArguments(for:)`); tests pass their own.
    @MainActor
    init(defaults: UserDefaults, info: [String: Any], launchArguments: [String: Any]? = nil) {
        let launchArguments = launchArguments ?? SettingSource.launchArguments(for: defaults)
        func read(_ key: String, default defaultValue: Bool) -> (value: Bool, source: SettingSource) {
            let value = (launchArguments[key] ?? defaults.object(forKey: key)).flatMap(Self.bool) ?? defaultValue
            let source = SettingSource.stored(
                key: key,
                defaults: defaults,
                launchArguments: launchArguments,
                parses: { Self.bool($0) != nil },
                isDefault: { Self.bool($0) == defaultValue }
            )
            return (value, source)
        }
        func sparkleSwitch(_ key: String) -> Switch {
            let defaultValue = info[key].flatMap(Self.bool) ?? true
            let (value, source) = read(key, default: defaultValue)
            return Switch(key: key, value: value, defaultValue: defaultValue, source: source)
        }
        automaticChecks = sparkleSwitch(Self.automaticChecksKey)
        automaticDownloads = sparkleSwitch(Self.automaticDownloadsKey)
        let prereleases = read(AppUpdateModel.prereleasesKey, default: false)
        self.prereleases = prereleases.value
        prereleasesSource = prereleases.source
    }

    /// A stored value as `UserDefaults.bool(forKey:)` reads it, which is how
    /// Sparkle and `AppUpdateModel` read these keys: a Boolean or a number,
    /// or a string by `NSString.boolValue` ("YES", "true", "1": a launch
    /// argument's); nil for anything else.
    static func bool(_ value: Any) -> Bool? {
        if let number = value as? NSNumber { return number.boolValue }
        if let string = value as? String { return (string as NSString).boolValue }
        return nil
    }
}
