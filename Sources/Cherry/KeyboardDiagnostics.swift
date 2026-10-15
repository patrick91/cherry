// Temporary keyboard diagnostics; remove once the Shift+Enter/Shift+Tab report is understood.
//
// Help › Keyboard Diagnostics…: the Ghostty config files Ghostty and Cherry
// read, the keyboard lines Cherry applies to its terminals, this Mac's
// version and input source, the TERM a new tab gets, what Cherry knows of
// the front tab's and the key test tab's keyboard, and a key test tab
// (`CherryMCP --key-echo`) whose log this window reads. Copy Report puts it
// all on the pasteboard as text.
//
// Settings › Terminal's Ghostty config section and its Copy Report
// (GhosttyConfigSettings.swift) use the same parts (`configFiles`, `masked`,
// `Tab`, `newTabEnvironment`, `inputSourceID`, `Report`): they stay when the
// window goes.

import AppKit
import Carbon.HIToolbox
import CherryControl
import SwiftUI

enum KeyboardDiagnostics {
    struct ConfigFile: Equatable {
        var path: String
        var exists: Bool
        /// A file a `config-file` line named, not one of the files Ghostty
        /// looks for (`TerminalSettings.ghosttyDefaultConfigPaths`).
        var isIncluded: Bool
        /// Cherry read its keyboard lines at launch
        /// (`TerminalSettings.nativeUserKeyboardConfigReading`).
        var readByCherry: Bool
        /// Cherry would read it if it launched now: another answer than
        /// `readByCherry` when a file was added, moved or removed since.
        var readByCherryNext: Bool
        /// Read at launch and now, with other keyboard lines now.
        var changedSinceLaunch = false
        /// Its keybind and macos-option-as-alt lines as Cherry reads them
        /// now, and what it does with each.
        var lines: [ConfigLine]

        var state: String {
            var parts = [exists ? "exists" : "missing"]
            if isIncluded { parts.append("named by a config-file line") }
            switch (readByCherry, readByCherryNext) {
            case (true, true) where changedSinceLaunch:
                parts.append("read by Cherry, changed since launch (these lines apply from its next launch)")
            case (true, true): parts.append("read by Cherry")
            case (true, false): parts.append("read by Cherry at launch, not from its next launch")
            case (false, true): parts.append("read by Cherry from its next launch (changed since launch)")
            case (false, false): break
            }
            return parts.joined(separator: ", ")
        }
    }

    /// A keyboard line of a config file (`masked`), and what Cherry does
    /// with it.
    struct ConfigLine: Equatable {
        var text: String
        /// Cherry's terminals take it (`UserGhosttyKeyboardConfig.Line.isApplied`).
        var isApplied: Bool
        /// The embedded Ghostty's diagnostic for a line it rejects, which
        /// Cherry leaves out.
        var rejection: String?

        var state: String {
            if let rejection { return "left out: Ghostty rejects it (\(rejection))" }
            return isApplied ? "applied" : "not applied"
        }
    }

    /// Ghostty's files (`defaultPaths`), then the files their `config-file`
    /// lines name, with whether Cherry read them at launch (`atLaunch`) and
    /// would read them now (`now`), and their keyboard lines now.
    nonisolated static func configFiles(
        defaultPaths: [URL],
        atLaunch: UserGhosttyKeyboardConfig?,
        now: UserGhosttyKeyboardConfig,
        fileExists: (String) -> Bool
    ) -> [ConfigFile] {
        let readAtLaunch = atLaunch?.files.map(\.path) ?? []
        let readNow = now.files.map(\.path)
        var paths = defaultPaths.map(\.path)
        for path in readAtLaunch + readNow where !paths.contains(path) {
            paths.append(path)
        }
        return paths.map { path in
            let lines = now.lines.filter { $0.file.path == path }
            let linesAtLaunch = atLaunch?.lines.filter { $0.file.path == path } ?? []
            return ConfigFile(
                path: path,
                exists: fileExists(path),
                isIncluded: !defaultPaths.contains { $0.path == path },
                readByCherry: readAtLaunch.contains(path),
                readByCherryNext: readNow.contains(path),
                changedSinceLaunch: readAtLaunch.contains(path) && readNow.contains(path)
                    && linesAtLaunch.map { [$0.key, $0.value] } != lines.map { [$0.key, $0.value] },
                lines: lines.map { line in
                    ConfigLine(
                        text: masked("\(line.key) = \(line.value)"),
                        isApplied: line.isApplied,
                        rejection: line.rejection.map { masked($0.trimmingCharacters(in: .whitespaces)) }
                    )
                }
            )
        }
    }

    /// A `text:` keybind's words (three letters or more, outside its
    /// escapes) as `***`: the report goes into issues, and a keybind may type
    /// private text. Its control bytes and escape sequences, what the
    /// report is about, stay.
    nonisolated static func masked(_ line: String) -> String {
        guard let text = line.range(of: "text:") else { return line }
        var result = String(line[..<text.upperBound])
        var word = ""
        func flush() {
            result += word.count >= 3 ? "***" : word
            word = ""
        }
        let payload = Array(line[text.upperBound...])
        var index = 0
        while index < payload.count {
            let character = payload[index]
            if character == "\\" {
                flush()
                var end = min(index + 2, payload.count)
                if index + 1 < payload.count {
                    if payload[index + 1] == "x" { end = min(index + 4, payload.count) }
                    if payload[index + 1] == "u", let close = payload[index...].firstIndex(of: "}") { end = close + 1 }
                }
                result += String(payload[index..<end])
                index = end
                continue
            }
            if character.isLetter {
                word.append(character)
            } else {
                flush()
                result.append(character)
            }
            index += 1
        }
        flush()
        return result
    }

    // MARK: Key test

    /// Where the key test tab's `--key-echo` logs.
    static var keyLogURL: URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Caches", isDirectory: true)
        return caches
            .appendingPathComponent(CherryAppIdentity.current.applicationSupportName, isDirectory: true)
            .appendingPathComponent("Keyboard Diagnostics", isDirectory: true)
            .appendingPathComponent("key-echo.jsonl", isDirectory: false)
    }

    /// What the key test tab's shell runs.
    nonisolated static func keyTestCommand(helper: String, log: String) -> String {
        "\(RemoteDeviceProbe.singleQuoted(helper)) --key-echo --log \(RemoteDeviceProbe.singleQuoted(log))"
    }

    /// One line of `--key-echo`'s log (CherryMCP's `KeyEchoLogRecord`).
    struct KeyLogRecord: Decodable, Equatable {
        var event: String
        var time: String
        var mode: String
        var hex: String?
        var escaped: String?
        var name: String?
        var term: String?
        var termProgram: String?
        var termProgramVersion: String?
        var place: String?
        var before: String?

        enum CodingKeys: String, CodingKey {
            case event, time, mode, hex, escaped, name, term, place, before
            case termProgram = "term_program"
            case termProgramVersion = "term_program_version"
        }

        /// A run's start separates it from the runs before it, with where it
        /// ran and the terminal variables it got.
        var line: String {
            switch event {
            case "start":
                let variables = terminalVariables(
                    ["TERM": term, "TERM_PROGRAM": termProgram, "TERM_PROGRAM_VERSION": termProgramVersion].compactMapValues(\.self)
                )
                return "── run \(time) in \(place ?? "an unknown terminal") · \(variables) · before any change: \(before ?? "not asked")"
            case "mode":
                return "── mode \(mode): wrote \(escaped ?? "")"
            default:
                return "[\(mode)] \(name ?? "?")   \(escaped ?? "")   \(hex ?? "")"
            }
        }
    }

    /// The log's last `limit` records, runs and mode switches included.
    nonisolated static func keyLog(_ text: String, limit: Int = 60) -> [KeyLogRecord] {
        let decoder = JSONDecoder()
        let records = text.split(whereSeparator: \.isNewline).compactMap {
            try? decoder.decode(KeyLogRecord.self, from: Data($0.utf8))
        }
        return Array(records.suffix(limit))
    }

    /// The log's last 256 KiB.
    nonisolated static func readKeyLog(at url: URL) -> [KeyLogRecord] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [] }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        return keyLog(String(decoding: data, as: UTF8.self))
    }

    // MARK: Tabs

    /// What Cherry knows of a tab's keyboard: where its program runs,
    /// whether its keys go through Ghostty's surface or the session host,
    /// and the keyboard modes its program asked for, as the host reports
    /// them (a native tab's are Ghostty's surface's alone).
    struct Tab: Equatable {
        struct HostModes: Equatable {
            var program: String?
            var kittyFlags: UInt32?
            var modifyOtherKeys: Bool?
            var applicationCursorKeys: Bool?
        }

        var id: UUID
        var title: String
        var project: String
        var isRunning = true
        var isPersistent = false
        var fallbackReason: String?
        var adapter: HostedAdapterLiveStatus?
        var inputGoesThroughHost = false
        /// Nil while the host reports no running session for it.
        var host: HostModes?

        var lines: [String] {
            let name = "“\(title)” in \(project)"
            guard isRunning else { return ["\(name): not running"] }
            guard isPersistent else {
                let backend = fallbackReason.map { "native tab, not a persistent session: \($0)" } ?? "native tab"
                return [
                    "\(name): \(backend)",
                    "  keys: Ghostty's surface encodes them, with Cherry's keybinds",
                    "  modes: Ghostty's surface keeps them; Cherry cannot read a native tab's",
                ]
            }
            let adapter = switch adapter {
            case nil: "its adapter is not attached"
            case let status? where status.reconnecting: "its adapter reconnects"
            case let status? where status.viewport: "its adapter is attached (viewport)"
            case _?: "its adapter is attached"
            }
            let keys = inputGoesThroughHost
                ? "keys: Cherry types them through the session host (HostRoutedKeyEncoder; keybinds do not apply)"
                : "keys: Ghostty's surface encodes them, with Cherry's keybinds, for the adapter"
            var modes = "modes: the session host reports none now"
            if let host {
                let flags = host.kittyFlags.map(String.init) ?? "not reported"
                let modifyOtherKeys = host.modifyOtherKeys.map { $0 ? "2" : "off" } ?? "not reported"
                let cursorKeys = host.applicationCursorKeys.map { $0 ? "on" : "off" } ?? "not reported"
                modes = "modes \(host.program.map { "\($0) asked for" } ?? "asked for"), as the session host reports them: "
                    + "kitty flags \(flags), modifyOtherKeys \(modifyOtherKeys), application cursor keys \(cursorKeys)"
            }
            return ["\(name): persistent session, \(adapter)", "  \(keys)", "  \(modes)"]
        }
    }

    @MainActor
    static func tab(_ session: TerminalSession, project: String) -> Tab {
        Tab(
            id: session.id,
            title: session.title,
            project: project,
            isRunning: session.isRunning,
            isPersistent: session.isPersistentLocalSession,
            fallbackReason: session.persistentFallbackReason,
            adapter: session.adapterLiveStatus,
            inputGoesThroughHost: session.keyboardInputGoesThroughHost,
            host: session.hostReportedSession.map {
                Tab.HostModes(
                    program: $0.foreground?.name.nilIfEmpty,
                    kittyFlags: $0.kittyKeyboardFlags,
                    modifyOtherKeys: $0.modifyOtherKeys,
                    applicationCursorKeys: $0.applicationCursorKeys
                )
            }
        )
    }

    /// The project window's name, as the report shows it.
    @MainActor
    static func projectName(_ workspace: TerminalWorkspace) -> String {
        workspace.projectRoot.map { URL(fileURLWithPath: ProjectLocation.launchPath(forKey: $0)).lastPathComponent } ?? "the front window"
    }

    // MARK: This Mac

    static func terminalVariables(_ environment: [String: String]) -> String {
        ["TERM", "TERM_PROGRAM", "TERM_PROGRAM_VERSION"]
            .map { "\($0)=\(environment[$0] ?? "(unset)")" }
            .joined(separator: " ")
    }

    /// A new local tab's environment, as its launch builds it: a persistent
    /// tab's from `HostedLaunchSpec` (`resources`: the staged Ghostty
    /// resources, nil when staging failed), a native tab's from Cherry's
    /// EXEC launch over what Ghostty's own Exec sets.
    static func newTabEnvironment(persistent: Bool, resources: GhosttyStagedResources?, processEnvironment: [String: String]) -> [String: String] {
        let configuration = ShellProcessController.Configuration(
            shellPath: "/bin/sh",
            workingDirectory: NSHomeDirectory(),
            term: ShellProcessController.preferredTerminfo.term,
            initialSize: TerminalViewportSize(columns: 80, rows: 24)
        )
        let version = HostedLaunchContext.embeddedGhosttyVersion
        if persistent {
            let context = HostedLaunchContext(
                processEnvironment: processEnvironment,
                loginEnvironment: nil,
                account: nil,
                launchedFromDesktop: false,
                ghosttyResources: resources,
                zshBootstrap: nil,
                executableDirectory: nil,
                terminalProgramVersion: version,
                shellFeatures: ""
            )
            return HostedLaunchSpec.make(for: configuration, context: context).environment
        }
        var environment = ["TERM_PROGRAM": "ghostty", "TERM_PROGRAM_VERSION": version ?? "(unknown)"]
        let cherry = ShellProcessController.nativeExecLaunch(
            for: configuration,
            shellIntegration: nil,
            inheritedEnvironment: processEnvironment,
            terminfoDirectories: ShellProcessController.preferredTerminfo.additionalDirs,
            mcpHelperPath: nil
        )
        environment.merge(cherry.environment) { _, cherry in cherry }
        return environment
    }

    static func inputSourceID(_ source: TISInputSource?) -> String {
        guard let source, let property = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "(unknown)" }
        return Unmanaged<CFString>.fromOpaque(property).takeUnretainedValue() as String
    }

    // MARK: Report

    struct Report: Equatable {
        var version = ""
        var build = ""
        var macOS = ""
        var inputSource = ""
        var keyboardLayout = ""
        var persistentSessions = false
        /// Why new tabs run natively although the setting is on
        /// (`PersistentSessionsStatus.localSessionsUnavailableReason`).
        var persistentSessionsUnavailable: String?
        /// The latest tab whose session could not start
        /// (`PersistentSessionsStatus.lastLaunchFailure`).
        var lastSessionLaunchFailure: String?
        var persistentTab: String?
        var nativeTab = ""
        var homeDirectory = ""
        var configFiles: [ConfigFile] = []
        var appliedKeyboardLines: [String] = []
        /// The selected tab of the front project window on This Mac.
        var frontTab: Tab?
        /// Whether `text` has the key test's parts: Settings › Terminal's
        /// Copy Report has no key test (`GhosttyConfigReport`).
        var includesKeyTest = true
        var keyTestTab: Tab?
        var keyLog: [KeyLogRecord] = []

        func shortened(_ path: String) -> String {
            guard !homeDirectory.isEmpty, path.hasPrefix(homeDirectory + "/") else { return path }
            return "~" + path.dropFirst(homeDirectory.count)
        }

        var persistentSessionsState: String {
            guard persistentSessions else { return "off" }
            return persistentSessionsUnavailable.map { "on, but new tabs run natively: \($0)" } ?? "on"
        }

        var frontTabLines: [String] {
            guard let frontTab else { return ["Front tab: no project window on This Mac"] }
            if frontTab.id == keyTestTab?.id { return ["Front tab: the key test tab"] }
            return ["Front tab: " + frontTab.lines[0]] + frontTab.lines.dropFirst()
        }

        var keyTestTabLines: [String] {
            guard let keyTestTab else { return ["Key test tab: none open"] }
            return ["Key test tab: " + keyTestTab.lines[0]] + keyTestTab.lines.dropFirst()
        }

        var text: String {
            var lines = [
                "Cherry keyboard diagnostics",
                "Cherry \(version) (\(build))",
                "macOS \(macOS)",
                "Input source: \(inputSource)",
                "Keyboard layout: \(keyboardLayout)",
                "Persistent sessions: \(persistentSessionsState)",
            ]
            if let lastSessionLaunchFailure { lines.append("Last session that could not start: \(lastSessionLaunchFailure)") }
            if let persistentTab { lines.append("New persistent tab: \(persistentTab)") }
            lines.append("New native tab: \(nativeTab)")
            lines.append("")
            lines.append("Ghostty config files, in Ghostty's order:")
            for file in configFiles {
                lines.append("  \(shortened(file.path)): \(file.state)")
                lines += file.lines.map { "    \($0.text)   (\($0.state))" }
            }
            if !configFiles.contains(where: { $0.readByCherry || $0.readByCherryNext }) { lines.append("  Cherry reads none of them.") }
            lines.append("Applied to Cherry's terminals (read once, at launch):")
            lines += appliedKeyboardLines.map { "  \($0)" }
            lines.append("")
            lines += frontTabLines
            if includesKeyTest {
                lines += keyTestTabLines
                lines.append("Key test log:")
                lines += keyLog.isEmpty ? ["  No keys yet."] : keyLog.map { "  \($0.line)" }
            }
            return lines.joined(separator: "\n") + "\n"
        }
    }
}

/// The Keyboard Diagnostics window's state.
@MainActor
final class KeyboardDiagnosticsModel: ObservableObject {
    @Published private(set) var report = KeyboardDiagnostics.Report()
    @Published private(set) var message: String?
    let keyLogURL: URL
    /// The latest key test tab, followed across the window's closes.
    private static weak var keyTestSession: TerminalSession?
    private static var keyTestProject = ""

    init(keyLogURL: URL = KeyboardDiagnostics.keyLogURL) {
        self.keyLogURL = keyLogURL
        refresh()
    }

    /// Everything but the new tabs' TERM (`refreshTerminalEnvironments`),
    /// the tabs and the key log (`refreshLive`).
    func refresh() {
        var report = report
        GhosttyConfigReport.fill(&report, from: .app())
        self.report = report
    }

    func refreshTerminalEnvironments() async {
        var resources: GhosttyStagedResources?
        if report.persistentSessions { resources = try? await GhosttyResourceStager.shared.resolve() }
        var report = report
        GhosttyConfigReport.fillNewTabs(&report, resources: resources, environment: ProcessInfo.processInfo.environment)
        self.report = report
    }

    /// The key log, the front tab and the key test tab, as they are now.
    func refreshLive() async {
        let url = keyLogURL
        let log = await Task.detached { KeyboardDiagnostics.readKeyLog(at: url) }.value
        var report = report
        report.keyLog = log
        if let workspace = ProjectWindowRegistry.shared.frontmostLocalWorkspace(), let session = workspace.selectedSession {
            report.frontTab = KeyboardDiagnostics.tab(session, project: KeyboardDiagnostics.projectName(workspace))
        } else {
            report.frontTab = nil
        }
        report.keyTestTab = Self.keyTestSession.map { KeyboardDiagnostics.tab($0, project: Self.keyTestProject) }
        if report != self.report { self.report = report }
    }

    /// A terminal tab in the front project window on This Mac whose shell
    /// runs `CherryMCP --key-echo`, opened as any new tab is (persistent
    /// when This Mac's tabs are).
    func openKeyTestTab() {
        guard let command = keyTestCommand() else { return }
        guard let workspace = ProjectWindowRegistry.shared.frontmostLocalWorkspace() else {
            message = "Open a project window on This Mac first."
            return
        }
        let tab = workspace.addSession(title: "Key Test", command: command)
        Self.keyTestSession = tab
        Self.keyTestProject = KeyboardDiagnostics.projectName(workspace)
        report.keyTestTab = KeyboardDiagnostics.tab(tab, project: Self.keyTestProject)
        message = "Opened “Key Test” in \(Self.keyTestProject). Press keys there; they show here."
        // The window that shows `workspace`, never another window of its project.
        ProjectWindowRegistry.shared.chromeState(for: workspace)?.selectTerminal()
        ProjectWindowRegistry.shared.focus(workspace: workspace)
    }

    /// The key test's command, to run in Ghostty or another terminal and
    /// compare: its keys show here too.
    func copyKeyTestCommand() {
        guard let command = keyTestCommand() else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(command, forType: .string)
        message = "Copied the key test command. Run it in Ghostty to compare; its keys show here too."
    }

    private func keyTestCommand() -> String? {
        guard let helper = ShellProcessController.appMCPHelperPath else {
            message = "This copy of Cherry has no CherryMCP next to its executable."
            return nil
        }
        try? FileManager.default.createDirectory(
            at: keyLogURL.deletingLastPathComponent(),
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return KeyboardDiagnostics.keyTestCommand(helper: helper, log: keyLogURL.path)
    }

    func copyReport() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.text, forType: .string)
        message = "Copied the report."
    }
}

struct KeyboardDiagnosticsView: View {
    @ObservedObject var model: KeyboardDiagnosticsModel

    var body: some View {
        let report = model.report
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text("Temporary: what Cherry does with Shift+Enter, Shift+Tab and the keyboard protocols. Copy the report into the issue; words that text: keybinds type show as ***.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    GroupBox("Ghostty config (Ghostty's order)") {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(report.configFiles, id: \.path) { file in
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                                        Image(systemName: file.exists ? "doc.text.fill" : "doc")
                                            .foregroundStyle(file.exists ? HierarchicalShapeStyle.primary : .tertiary)
                                        Text(report.shortened(file.path)).font(.system(.body, design: .monospaced))
                                        Text(file.state)
                                            .foregroundStyle(file.readByCherry || file.readByCherryNext ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                    }
                                    ForEach(Array(file.lines.enumerated()), id: \.offset) { _, line in
                                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                                            Text(line.text).font(.system(.caption, design: .monospaced))
                                            Text(line.state)
                                                .font(.caption)
                                                .foregroundStyle(line.rejection != nil ? AnyShapeStyle(.red)
                                                    : line.isApplied ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                                        }
                                        .padding(.leading, 22)
                                    }
                                }
                            }
                            if !report.configFiles.contains(where: { $0.readByCherry || $0.readByCherryNext }) {
                                Text("Cherry reads none of them.").foregroundStyle(.secondary)
                            }
                            Divider()
                            Text("Applied to Cherry's terminals (read once, at launch)").font(.callout.weight(.medium))
                            ForEach(Array(report.appliedKeyboardLines.enumerated()), id: \.offset) { _, line in
                                Text(line).font(.system(.caption, design: .monospaced))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    }

                    GroupBox("This Mac") {
                        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 12, verticalSpacing: 4) {
                            row("Cherry", "\(report.version) (\(report.build))")
                            row("macOS", report.macOS)
                            row("Input source", report.inputSource)
                            row("Keyboard layout", report.keyboardLayout)
                            row("Persistent sessions", report.persistentSessionsState)
                            if let failure = report.lastSessionLaunchFailure { row("Last session that could not start", failure) }
                            if let persistentTab = report.persistentTab { row("New persistent tab", persistentTab) }
                            row("New native tab", report.nativeTab)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    }

                    GroupBox("Tabs") {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array((report.frontTabLines + report.keyTestTabLines).enumerated()), id: \.offset) { _, line in
                                Text(line).font(.system(.caption, design: .monospaced))
                            }
                            Text("Open this window while Claude Code or lazygit runs in the front tab to see the modes it asked for.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .padding(.top, 4)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    }

                    GroupBox("Key test") {
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Button("Open Key Test Tab") { model.openKeyTestTab() }
                                Button("Copy Command") { model.copyKeyTestCommand() }
                            }
                            Text("Open Key Test Tab runs CherryMCP --key-echo in a new tab of the front project window. Press Enter, Shift+Enter and Shift+Tab in each mode (keys 1–4); q quits. For a native tab, turn off Settings › Sessions › Run local terminals as persistent sessions first. Copy Command runs the same test in Ghostty, to compare.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                            if report.keyLog.isEmpty {
                                Text("No keys yet.").foregroundStyle(.secondary)
                            }
                            ForEach(Array(report.keyLog.enumerated()), id: \.offset) { _, record in
                                Text(record.line)
                                    .font(.system(.caption, design: .monospaced))
                                    .foregroundStyle(record.event == "key" ? HierarchicalShapeStyle.primary : .secondary)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    }
                }
                .padding(20)
            }
            Divider()
            HStack {
                if let message = model.message {
                    Text(message).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("Refresh") {
                    model.refresh()
                    Task { await model.refreshTerminalEnvironments() }
                }
                Button("Copy Report") { model.copyReport() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(minWidth: 620, idealWidth: 720, minHeight: 520, idealHeight: 760)
        .task {
            await model.refreshTerminalEnvironments()
            while !Task.isCancelled {
                await model.refreshLive()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        GridRow {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }
}

/// The one Keyboard Diagnostics window (Help › Keyboard Diagnostics…).
@MainActor
enum KeyboardDiagnosticsWindow {
    private static var window: NSWindow?
    private static var closeObserver: NSObjectProtocol?

    static func show() {
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 760),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: true
        )
        window.title = "Keyboard Diagnostics"
        window.isReleasedWhenClosed = false
        window.contentViewController = NSHostingController(rootView: KeyboardDiagnosticsView(model: KeyboardDiagnosticsModel()))
        window.center()
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                if let closeObserver { NotificationCenter.default.removeObserver(closeObserver) }
                closeObserver = nil
                Self.window = nil
            }
        }
        Self.window = window
        window.makeKeyAndOrderFront(nil)
    }
}
