import AppKit
import Carbon.HIToolbox
import Foundation

/// What Settings › Terminal says of the user's Ghostty config: the Option
/// key Cherry's terminals use, how many of its key
/// bindings they take, the files Cherry reads and the lines Ghostty
/// rejects. Pure functions of readings (`UserGhosttyKeyboardConfig`): the
/// launch reading is what Cherry's terminals use until it quits; a fresh
/// one, which the page takes only in its `.task` (it runs the embedded
/// Ghostty's check on the main actor), says what changed since. Cherry
/// never writes these files.
enum GhosttyConfigSettings {
    /// Under a file, or a row, whose lines differ from those Cherry read
    /// when it opened.
    static let changedSinceLaunchNote = "Changed since Cherry opened. Restart Cherry to use it."

    /// Terminal › Scrollback › In a shown tab: "4 MB".
    static var shownTabScrollbackText: String {
        "\(TerminalSettings.shownTabScrollbackBytes / 1_000_000) MB"
    }

    // MARK: Option key

    /// The Option key's choices, in the pop-up's order
    /// (`macos-option-as-alt` true, false, left, right).
    static let optionKeyChoices: [HostRoutedKeyEncoder.OptionAsAlt] = [.both, .neither, .left, .right]

    /// What the Option key's choices do: its row's help, whatever sets it.
    static let optionKeyHelp = "Alt sends Esc and the key, as shells and editors expect. Typing characters keeps @, #, [ ], { } and ~ on layouts that type them with Option."

    /// Terminal › Keyboard › Option key, read-only in v1: the value Cherry's
    /// terminals use (the last `macos-option-as-alt` line they take, as the
    /// host-routed keys read it too, else Cherry's default, Option is Alt),
    /// the line that sets it, and what to tell about the file.
    struct OptionKey: Equatable {
        var value: HostRoutedKeyEncoder.OptionAsAlt
        /// The line that sets it; nil for Cherry's default.
        var line: UserGhosttyKeyboardConfig.Line?
        /// The last line that sets it, when Ghostty rejects it: Cherry
        /// leaves it out and uses the line before it, or its default.
        var leftOut: UserGhosttyKeyboardConfig.Line?
        /// The files' lines for it now are not those Cherry read when it
        /// opened: a restart changes it.
        var changedSinceLaunch = false

        /// What Edit in Ghostty Config opens: the left-out line's file, else
        /// the line's; nil when no line is about it.
        var file: URL? {
            leftOut?.file ?? line?.file
        }

        /// "Set by your Ghostty config: ~/.config/ghostty/config, line 12."
        /// above what the choices do.
        func help(homeDirectory: String) -> String {
            guard let line else { return GhosttyConfigSettings.optionKeyHelp }
            let location = SettingsSourceState.ghosttyLocation(file: line.file, line: line.line, homeDirectory: homeDirectory)
            return "Set by your Ghostty config: \(location).\n\(GhosttyConfigSettings.optionKeyHelp)"
        }

        /// "Your Ghostty config's line is left out: invalid value".
        var leftOutNote: String? {
            leftOut.map { "Your Ghostty config's line is left out: \(GhosttyConfigSettings.rejectionReason(of: $0))" }
        }

        /// What search shows of it: who sets it, else its value.
        var searchValue: String {
            line == nil ? value.settingsLabel : "set by your Ghostty config"
        }

        /// "Left Option is Alt, set by your Ghostty config".
        var accessibilityValue: String {
            line == nil ? value.settingsLabel : "\(value.settingsLabel), set by your Ghostty config"
        }
    }

    /// The Option key as Cherry read it when it opened (`launch`); `now`, a
    /// fresh reading, says whether it changed since.
    static func optionKey(launch: UserGhosttyKeyboardConfig?, now: UserGhosttyKeyboardConfig?) -> OptionKey {
        let lines = optionKeyLines(launch)
        let line = lines.last { $0.isApplied }
        let leftOut = lines.last.flatMap { $0.rejection == nil ? nil : $0 }
        let changed = now.map { now in
            optionKeyLines(now).map { [$0.file.path, $0.value] } != lines.map { [$0.file.path, $0.value] }
        } ?? false
        return OptionKey(
            value: HostRoutedKeyEncoder.OptionAsAlt(configValue: line?.value),
            line: line,
            leftOut: leftOut,
            changedSinceLaunch: changed
        )
    }

    private static func optionKeyLines(_ reading: UserGhosttyKeyboardConfig?) -> [UserGhosttyKeyboardConfig.Line] {
        reading?.lines.filter { $0.key == "macos-option-as-alt" } ?? []
    }

    // MARK: Key bindings

    /// The `keybind` lines that bind a key, as Shortcuts lists them: not
    /// `keybind = clear` or an empty `keybind =`, which bind nothing, nor a
    /// `chain=` line, which goes with the binding before it.
    static func bindingLines(_ reading: UserGhosttyKeyboardConfig?) -> [UserGhosttyKeyboardConfig.Line] {
        (reading?.lines ?? []).filter { line in
            guard line.key == "keybind", !line.value.isEmpty, line.value != "clear" else { return false }
            return TerminalSettings.keybindParts(line.value)?.trigger != "chain"
        }
    }

    /// Terminal › Keyboard › Key bindings from Ghostty: how many of the
    /// binding lines Cherry's terminals take, how many they leave to Cherry
    /// or to a later line, and how many Ghostty rejects.
    struct BindingCounts: Equatable {
        var applied = 0
        var notApplied = 0
        var leftOut = 0

        /// "2 applied · 1 not applied · 1 left out"; "None" without any.
        var text: String {
            guard applied + notApplied + leftOut > 0 else { return "None" }
            return "\(applied) applied · \(notApplied) not applied · \(leftOut) left out"
        }
    }

    static func bindingCounts(_ reading: UserGhosttyKeyboardConfig?) -> BindingCounts {
        var counts = BindingCounts()
        for line in bindingLines(reading) {
            if line.rejection != nil {
                counts.leftOut += 1
            } else if line.isApplied {
                counts.applied += 1
            } else {
                counts.notApplied += 1
            }
        }
        return counts
    }

    /// The Key bindings row's badge: the files its bindings are in, read
    /// only here. Nil without a binding.
    @MainActor
    static func bindingsSource(
        _ reading: UserGhosttyKeyboardConfig?,
        homeDirectory: String,
        actions: SettingsActions
    ) -> SettingsSourceState? {
        let lines = bindingLines(reading)
        guard let first = lines.first else { return nil }
        var files: [URL] = []
        for line in lines where !files.contains(line.file) {
            files.append(line.file)
        }
        var buttons: [SettingsAction] = []
        if files.count == 1 {
            buttons.append(SettingsAction("Edit in Ghostty Config") { actions.openTextFile(first.file) })
        }
        buttons.append(SettingsAction("Reveal in Finder") { actions.revealInFinder(files) })
        return SettingsSourceState(
            source: .ghosttyConfig(file: first.file, line: nil),
            lines: files.map { file in
                let count = lines.count { $0.file == file }
                return SettingsSourceState.Line(
                    "Ghostty config",
                    value: count == 1 ? "1 binding" : "\(count) bindings",
                    detail: ProjectSwitcherModel.displayPath(file.path, home: homeDirectory),
                    isInUse: true
                )
            },
            note: "Cherry reads these files when it opens. Restart Cherry after you change them.",
            buttons: buttons
        )
    }

    // MARK: Files

    /// A file of Terminal › Ghostty config: one Ghostty looks for, or one a
    /// `config-file` line named.
    struct File: Equatable, Identifiable {
        enum State: Equatable {
            /// Cherry read it when it opened, and it says the same now.
            case read
            /// Not there (or not a file Cherry can read): nothing to read.
            case missing
            /// Added, changed or removed since Cherry opened: its lines
            /// apply from Cherry's next launch.
            case changed

            var text: String {
                switch self {
                case .read: "Read"
                case .missing: "Missing"
                case .changed: "Changed"
                }
            }
        }

        var url: URL
        var state: State
        /// Whether it is there now: Open and Reveal in Finder only then.
        var exists: Bool
        /// The `config-file` line that named it.
        var includedBy: UserGhosttyKeyboardConfig.Inclusion?

        var id: String { url.path }

        /// "Named by config-file in config, line 3".
        var includedByText: String? {
            includedBy.map { "Named by config-file in \($0.file.lastPathComponent), line \($0.line)" }
        }
    }

    /// The files Ghostty looks for (`defaultPaths`), then those that
    /// `config-file` lines named, as Cherry read them when it opened
    /// (`launch`) and would now (`now`; `KeyboardDiagnostics.configFiles`).
    static func files(
        defaultPaths: [URL],
        launch: UserGhosttyKeyboardConfig?,
        now: UserGhosttyKeyboardConfig,
        fileExists: (String) -> Bool
    ) -> [File] {
        KeyboardDiagnostics.configFiles(defaultPaths: defaultPaths, atLaunch: launch, now: now, fileExists: fileExists)
            .map { file in
                let state: File.State = if file.changedSinceLaunch || file.readByCherry != file.readByCherryNext {
                    .changed
                } else if file.exists, file.readByCherry {
                    .read
                } else {
                    .missing
                }
                return File(
                    url: URL(fileURLWithPath: file.path),
                    state: state,
                    exists: file.exists,
                    includedBy: file.isIncluded ? now.includedBy[file.path] ?? launch?.includedBy[file.path] : nil
                )
            }
    }

    // MARK: Lines left out

    /// A line Ghostty rejects, so Cherry's terminals leave it out (the
    /// rest of its file still applies).
    struct LeftOutLine: Equatable, Identifiable {
        var line: UserGhosttyKeyboardConfig.Line

        var id: String { "\(line.file.path):\(line.line)" }

        /// "keys.conf, line 7".
        var location: String {
            "\(line.file.lastPathComponent), line \(line.line)"
        }

        /// "keybind = ctrl+shift+x=new_spilt:right".
        var text: String {
            "\(line.key) = \(line.value)"
        }

        /// "Ghostty: invalid value".
        var reason: String {
            "Ghostty: \(GhosttyConfigSettings.rejectionReason(of: line))"
        }
    }

    /// The lines of `reading` Ghostty rejects, in Ghostty's order.
    static func linesLeftOut(_ reading: UserGhosttyKeyboardConfig?) -> [LeftOutLine] {
        (reading?.lines ?? []).filter { $0.rejection != nil }.map(LeftOutLine.init)
    }

    /// Ghostty's diagnostic for a line it rejects, without the key it
    /// starts with ("keybind: invalid value" is "invalid value").
    static func rejectionReason(of line: UserGhosttyKeyboardConfig.Line) -> String {
        var reason = (line.rejection ?? "").trimmingCharacters(in: .whitespaces)
        if reason.hasPrefix(line.key + ":") {
            reason = String(reason.dropFirst(line.key.count + 1)).trimmingCharacters(in: .whitespaces)
        }
        return reason
    }

    /// The user's Ghostty files read now, as Cherry's terminals read them:
    /// none while `TerminalSettings.readsUserGhosttyConfiguration` is off
    /// (tests). Terminal's Ghostty config, Copy Report and the Keyboard
    /// Diagnostics window read them so.
    @MainActor
    static func readNow(home: URL, environment: [String: String]) -> UserGhosttyKeyboardConfig {
        TerminalSettings.readsUserGhosttyConfiguration
            ? TerminalSettings.ghosttyKeyboardConfig(home: home, environment: environment)
            : UserGhosttyKeyboardConfig()
    }
}

extension HostRoutedKeyEncoder.OptionAsAlt {
    /// Its name in Settings › Terminal.
    var settingsLabel: String {
        switch self {
        case .both: "Option is Alt"
        case .neither: "Option types characters"
        case .left: "Left Option is Alt"
        case .right: "Right Option is Alt"
        }
    }
}

// MARK: - Page model

/// Settings › Terminal's view of the user's Ghostty config: the rows of
/// the reading Cherry took when it opened, and the files as they are now,
/// read again (`refresh`) only from the page's `.task` and when Cherry
/// comes to the front, never in a view update or a search.
@MainActor
final class GhosttyConfigPageModel: ObservableObject {
    /// What Cherry read at launch: what its terminals use until it quits.
    let launchReading: UserGhosttyKeyboardConfig?
    /// Empty until the first `refresh`.
    @Published private(set) var files: [GhosttyConfigSettings.File] = []
    @Published private(set) var optionKey: GhosttyConfigSettings.OptionKey

    private let defaultPaths: [URL]
    private let read: @MainActor () -> UserGhosttyKeyboardConfig
    private let fileExists: (String) -> Bool

    /// `read` reads the files now (`TerminalSettings.ghosttyKeyboardConfig`);
    /// tests read a home of their own.
    init(
        launchReading: UserGhosttyKeyboardConfig?,
        defaultPaths: [URL],
        read: @escaping @MainActor () -> UserGhosttyKeyboardConfig,
        fileExists: @escaping (String) -> Bool
    ) {
        self.launchReading = launchReading
        self.defaultPaths = defaultPaths
        self.read = read
        self.fileExists = fileExists
        optionKey = GhosttyConfigSettings.optionKey(launch: launchReading, now: nil)
    }

    /// The app's: the user's files, read as Cherry's terminals read them
    /// (none while `readsUserGhosttyConfiguration` is off). Only the app's
    /// Settings window makes it.
    static func app() -> GhosttyConfigPageModel {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let environment = ProcessInfo.processInfo.environment
        return GhosttyConfigPageModel(
            launchReading: TerminalSettings.nativeUserKeyboardConfigReading,
            defaultPaths: TerminalSettings.ghosttyDefaultConfigPaths(home: home, environment: environment),
            read: { GhosttyConfigSettings.readNow(home: home, environment: environment) },
            fileExists: { FileManager.default.fileExists(atPath: $0) }
        )
    }

    var bindingCounts: GhosttyConfigSettings.BindingCounts {
        GhosttyConfigSettings.bindingCounts(launchReading)
    }

    var linesLeftOut: [GhosttyConfigSettings.LeftOutLine] {
        GhosttyConfigSettings.linesLeftOut(launchReading)
    }

    /// Reads the files again and publishes only what changed.
    func refresh() {
        let now = read()
        let files = GhosttyConfigSettings.files(
            defaultPaths: defaultPaths,
            launch: launchReading,
            now: now,
            fileExists: fileExists
        )
        if files != self.files { self.files = files }
        let optionKey = GhosttyConfigSettings.optionKey(launch: launchReading, now: now)
        if optionKey != self.optionKey { self.optionKey = optionKey }
    }
}

// MARK: - Report

/// Settings › Terminal's Copy Report: what the Keyboard
/// Diagnostics window reports (`KeyboardDiagnostics.Report`) without its
/// key test: Cherry's version and this Mac's, the files and what Cherry
/// does with each of their keyboard lines (`text:` words masked), the
/// lines its terminals take, the TERM a new tab gets and the front tab's
/// keyboard. Built when Copy Report is clicked, from `Sources`, which tests
/// make of fakes.
enum GhosttyConfigReport {
    /// Where the report's parts come from.
    @MainActor
    struct Sources {
        /// The app bundle's Info.plist.
        var info: [String: Any]
        var macOS: String
        var inputSource: String
        var keyboardLayout: String
        var persistentSessions: Bool
        /// Why new tabs run natively although persistent sessions are on.
        var persistentSessionsUnavailable: String?
        var lastSessionLaunchFailure: String?
        var home: URL
        var environment: [String: String]
        /// What Cherry read when it opened.
        var launchReading: UserGhosttyKeyboardConfig?
        /// Reads the files now.
        var read: @MainActor () -> UserGhosttyKeyboardConfig
        var fileExists: (String) -> Bool
        /// What Cherry's terminals take (`TerminalSettings.nativeUserKeyboardConfig`).
        var appliedKeyboardLines: [(String, String)]
        /// The Ghostty resources a persistent tab's TERM depends on; asked
        /// only while persistent sessions are on.
        var stagedResources: @MainActor () async -> GhosttyStagedResources?
        /// The selected tab of the front project window on This Mac.
        var frontTab: @MainActor () -> KeyboardDiagnostics.Tab?

        /// This Mac's and the app's, as they are now. Only the app's
        /// Settings window reads them; tests never do.
        static func app() -> Sources {
            let status = PersistentSessionsStatus.shared
            let home = FileManager.default.homeDirectoryForCurrentUser
            let environment = ProcessInfo.processInfo.environment
            return Sources(
                info: Bundle.main.infoDictionary ?? [:],
                macOS: ProcessInfo.processInfo.operatingSystemVersionString,
                inputSource: KeyboardDiagnostics.inputSourceID(TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()),
                keyboardLayout: KeyboardDiagnostics.inputSourceID(TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()),
                persistentSessions: TerminalSettings.shared.persistLocalSessions,
                persistentSessionsUnavailable: status.localSessionsUnavailableReason,
                lastSessionLaunchFailure: status.lastLaunchFailure,
                home: home,
                environment: environment,
                launchReading: TerminalSettings.nativeUserKeyboardConfigReading,
                read: { GhosttyConfigSettings.readNow(home: home, environment: environment) },
                fileExists: { FileManager.default.fileExists(atPath: $0) },
                appliedKeyboardLines: TerminalSettings.nativeUserKeyboardConfig,
                stagedResources: { try? await GhosttyResourceStager.shared.resolve() },
                frontTab: {
                    guard let workspace = ProjectWindowRegistry.shared.frontmostLocalWorkspace(),
                          let session = workspace.selectedSession
                    else { return nil }
                    return KeyboardDiagnostics.tab(session, project: KeyboardDiagnostics.projectName(workspace))
                }
            )
        }
    }

    @MainActor
    static func build(from sources: Sources) async -> KeyboardDiagnostics.Report {
        var report = KeyboardDiagnostics.Report()
        report.includesKeyTest = false
        fill(&report, from: sources)
        report.frontTab = sources.frontTab()
        let resources = sources.persistentSessions ? await sources.stagedResources() : nil
        fillNewTabs(&report, resources: resources, environment: sources.environment)
        return report
    }

    /// What Copy Report and the Keyboard Diagnostics window both say,
    /// apart from the tabs and the new tabs' TERM: Cherry's version and
    /// this Mac's, its keyboard, persistent sessions, the lines Cherry's
    /// terminals take and the files.
    @MainActor
    static func fill(_ report: inout KeyboardDiagnostics.Report, from sources: Sources) {
        report.version = sources.info["CFBundleShortVersionString"] as? String ?? "unknown"
        report.build = sources.info["CFBundleVersion"] as? String ?? "unknown"
        report.macOS = sources.macOS
        report.inputSource = sources.inputSource
        report.keyboardLayout = sources.keyboardLayout
        report.persistentSessions = sources.persistentSessions
        report.persistentSessionsUnavailable = sources.persistentSessionsUnavailable
        report.lastSessionLaunchFailure = sources.lastSessionLaunchFailure
        report.homeDirectory = sources.home.path
        report.appliedKeyboardLines = sources.appliedKeyboardLines.map { KeyboardDiagnostics.masked("\($0.0) = \($0.1)") }
        report.configFiles = KeyboardDiagnostics.configFiles(
            defaultPaths: TerminalSettings.ghosttyDefaultConfigPaths(home: sources.home, environment: sources.environment),
            atLaunch: sources.launchReading,
            now: sources.read(),
            fileExists: sources.fileExists
        )
    }

    /// The TERM a new native tab gets, and a new persistent one's while
    /// `report` says persistent sessions are on (`resources`: the Ghostty
    /// resources it depends on).
    static func fillNewTabs(
        _ report: inout KeyboardDiagnostics.Report,
        resources: GhosttyStagedResources?,
        environment: [String: String]
    ) {
        report.nativeTab = KeyboardDiagnostics.terminalVariables(
            KeyboardDiagnostics.newTabEnvironment(persistent: false, resources: nil, processEnvironment: environment)
        )
        report.persistentTab = report.persistentSessions ? KeyboardDiagnostics.terminalVariables(
            KeyboardDiagnostics.newTabEnvironment(persistent: true, resources: resources, processEnvironment: environment)
        ) : nil
    }
}
