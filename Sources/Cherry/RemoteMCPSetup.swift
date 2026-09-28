import AppKit
import CherryControl
import Foundation
import SwiftUI

// "Set Up Cherry MCP on <Mac>…" (docs/specs/remote-devices.md, phase 4b):
// Claude Code and Codex on another Mac read their MCP servers from their own
// configuration there, which Cherry never edits by itself. The sheet shows
// the exact commands, and runs them over SSH only when the user confirms:
// it writes a stable launcher there (`RemoteMCPPaths.launcherRelativePath`)
// and registers it with each agent CLI it finds, or removes the
// registrations. Both are idempotent.

enum RemoteMCPSetup {
    enum Mode: String, Sendable {
        /// Looks for the agent CLIs and CherryMCP there (reads no agent
        /// configuration).
        case check
        /// Writes the launcher and registers it with Claude Code and Codex.
        case install
        /// Removes the registrations (the launcher stays: another Cherry
        /// may use it).
        case remove
    }

    /// The server's name in the agents' configuration: this Cherry's URL
    /// scheme ("cherry").
    static var serverName: String { CherryAppIdentity.current.urlScheme }

    /// The launcher as the commands name it there.
    static let launcherExpression = "\"$HOME/\(RemoteMCPPaths.launcherRelativePath)\""

    /// The commands the sheet shows, as the script runs them (`claude` and
    /// `codex` from that Mac's login PATH).
    static func commands(mode: Mode, name: String = serverName) -> [String] {
        switch mode {
        case .check:
            return []
        case .install:
            return [
                "# writes the launcher ~/\(RemoteMCPPaths.launcherRelativePath)",
                "claude mcp remove --scope user \(name); claude mcp add --scope user --transport stdio \(name) -- \(launcherExpression)",
                "codex mcp remove \(name); codex mcp add \(name) -- \(launcherExpression)",
                "# Codex passes an MCP server only the variables it lists: adds",
                "#   env_vars = \(codexEnvVars) to [mcp_servers.\(name)] in ~/.codex/config.toml",
            ]
        case .remove:
            return [
                "claude mcp remove --scope user \(name)",
                "codex mcp remove \(name)",
            ]
        }
    }

    /// The variables Codex must pass to CherryMCP (its `env_vars`): Codex
    /// starts MCP servers with only a few of its own.
    static var codexEnvVars: String {
        "[" + CherryControl.remoteTabEnvironmentKeys.map { "\"\($0)\"" }.joined(separator: ", ") + "]"
    }

    /// Puts `line` (the `env_vars` assignment) right after the table's
    /// header and drops the table's own `env_vars`, a multi-line array
    /// included; exits 3 when the table is not there.
    static let codexEnvVarsAwk = #"""
    skipping { if ($0 ~ /\]/) skipping = 0; next }
    /^[ \t]*\[/ { t = $0; gsub(/[ \t]/, "", t); inside = (t == table); print; if (inside) { print line; found = 1 }; next }
    inside && /^[ \t]*env_vars[ \t]*=/ { if ($0 !~ /\]/) skipping = 1; next }
    { print }
    END { exit found ? 0 : 3 }
    """#

    /// The launcher: runs the CherryMCP of the Cherry build that started
    /// the tab (`CHERRY_MCP_HELPER`), else the newest build installed there
    /// (by build id, as `HostBuildOrder` orders them),
    /// else that Mac's own Cherry.app's (for agents in that Cherry's tabs).
    static let launcher = """
    #!/bin/sh
    # Cherry MCP for agents on this Mac (written by Cherry's Set Up Cherry MCP).
    # In a tab another Mac's Cherry runs here: that Cherry build's CherryMCP.
    helper=${CHERRY_MCP_HELPER:-}
    if [ -z "$helper" ] || [ ! -x "$helper" ]; then
      # The newest build by its build id (its leading 14-digit time stamp),
      # not by name; a build without one only when there is no other.
      helper=
      best=-1
      for candidate in "$HOME/Library/Application Support/cherry-host/bin"/*/CherryMCP; do
        [ -x "$candidate" ] || continue
        name=${candidate%/CherryMCP}
        name=${name##*/}
        stamp=${name%%.*}
        case "$stamp" in
          [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;;
          *) stamp=0 ;;
        esac
        if [ "$stamp" -gt "$best" ]; then helper=$candidate; best=$stamp; fi
      done
    fi
    if [ -z "$helper" ]; then
      for candidate in /Applications/Cherry.app/Contents/MacOS/CherryMCP "$HOME/Applications/Cherry.app/Contents/MacOS/CherryMCP"; do
        if [ -x "$candidate" ]; then helper=$candidate; break; fi
      done
    fi
    if [ -z "$helper" ]; then
      echo "cherry-mcp: no CherryMCP on this Mac (install Cherry's session host here from Cherry on another Mac)" >&2
      exit 1
    fi
    exec "$helper" "$@"
    """

    /// The script for `mode`, run with `sh -s` there. `helperPath`: the
    /// device's install's CherryMCP (checked with `--version`).
    static func script(mode: Mode, name: String = serverName, helperPath: String?) -> String {
        let quotedName = RemoteDeviceProbe.singleQuoted(name)
        var lines = [
            "printf '%s\\n' '\(RemoteDeviceProbe.beginMarker)'",
            "name=\(quotedName)",
            "launcher=\"$HOME\"/\(RemoteDeviceProbe.singleQuoted(RemoteMCPPaths.launcherRelativePath))",
            "helper=\(RemoteDeviceProbe.singleQuoted(helperPath ?? ""))",
            // The agent CLIs (and the node Claude Code may need) are on the
            // login shell's PATH.
            "lp=$(\"${SHELL:-/bin/sh}\" -l -c 'printf \"%s\" \"$PATH\"' </dev/null 2>/dev/null | tail -n 1)",
            "[ -n \"$lp\" ] && PATH=\"$lp:$PATH\"",
            "PATH=\"$PATH:$HOME/.local/bin:$HOME/.claude/local:/opt/homebrew/bin:/usr/local/bin\"",
            "export PATH",
            "claude=$(command -v claude 2>/dev/null)",
            "codex=$(command -v codex 2>/dev/null)",
            "printf 'claude=%s\\n' \"$claude\"",
            "printf 'codex=%s\\n' \"$codex\"",
            "if [ -n \"$helper\" ]; then",
            "  if [ -x \"$helper\" ]; then",
            "    if v=$(\"$helper\" --version 2>&1 </dev/null); then printf 'helper_version=%s\\n' \"$(printf '%s' \"$v\" | tr '\\n' ' ')\"; else printf 'helper_error=%s\\n' \"$(printf '%s' \"$v\" | tr '\\n' ' ' | cut -c1-300)\"; fi",
            "  else",
            "    echo helper_missing=1",
            "  fi",
            "fi",
            "result() { if out=$(\"$@\" 2>&1 </dev/null); then echo ok; else printf '%s' \"$out\" | tr '\\n' ' ' | cut -c1-300; echo; fi; }",
        ]
        switch mode {
        case .check:
            break
        case .install:
            lines += [
                "umask 022",
                "mkdir -p \"$(dirname \"$launcher\")\" && tmp=\"$launcher.tmp.$$\" && cat > \"$tmp\" <<'CHERRY_MCP_LAUNCHER'",
                launcher,
                "CHERRY_MCP_LAUNCHER",
                "if chmod 755 \"$tmp\" && mv -f \"$tmp\" \"$launcher\"; then echo launcher_written=1; else rm -f \"$tmp\"; echo launcher_error=1; fi",
                "if [ -n \"$claude\" ]; then",
                "  \"$claude\" mcp remove --scope user \"$name\" >/dev/null 2>&1 </dev/null",
                "  printf 'claude_result=%s\\n' \"$(result \"$claude\" mcp add --scope user --transport stdio \"$name\" -- \"$launcher\")\"",
                "fi",
                "if [ -n \"$codex\" ]; then",
                "  \"$codex\" mcp remove \"$name\" >/dev/null 2>&1 </dev/null",
                "  codex_result=$(result \"$codex\" mcp add \"$name\" -- \"$launcher\")",
                // Codex passes only the variables `env_vars` lists: added to
                // the table `codex mcp add` just wrote.
                "  cfg=\"${CODEX_HOME:-$HOME/.codex}/config.toml\"",
                "  if [ \"$codex_result\" = ok ]; then",
                // A linked config: its target is replaced, the link kept.
                "    target=$cfg",
                "    if [ -L \"$cfg\" ]; then target=$(/usr/bin/perl -MCwd=abs_path -e 'print abs_path(shift)' \"$cfg\"); fi",
                // Written next to it, then renamed over it: never half
                // written, whatever happens meanwhile.
                "    tmp=",
                "    if [ -n \"$target\" ] && [ -f \"$target\" ]; then tmp=$(/usr/bin/mktemp \"$(dirname \"$target\")/.config.toml.cherry.XXXXXX\"); fi",
                "    if [ -n \"$tmp\" ] && /usr/bin/awk -v table=\"[mcp_servers.$name]\" -v line=\(RemoteDeviceProbe.singleQuoted("env_vars = " + codexEnvVars)) \(RemoteDeviceProbe.singleQuoted(codexEnvVarsAwk)) \"$target\" > \"$tmp\"; then",
                "      /bin/chmod \"$(/usr/bin/stat -f %Lp \"$target\")\" \"$tmp\" && /bin/mv -f \"$tmp\" \"$target\" && echo codex_env=1",
                "    else",
                "      codex_result=\"codex mcp add did not write [mcp_servers.$name] to $cfg; add env_vars there yourself\"",
                "    fi",
                "    [ -n \"$tmp\" ] && /bin/rm -f \"$tmp\"",
                "  fi",
                "  printf 'codex_result=%s\\n' \"$codex_result\"",
                "fi",
            ]
        case .remove:
            lines += [
                "if [ -n \"$claude\" ]; then printf 'claude_result=%s\\n' \"$(result \"$claude\" mcp remove --scope user \"$name\")\"; fi",
                "if [ -n \"$codex\" ]; then printf 'codex_result=%s\\n' \"$(result \"$codex\" mcp remove \"$name\")\"; fi",
            ]
        }
        lines += [
            "[ -x \"$launcher\" ] && echo launcher=1",
            "printf '%s\\n' '\(RemoteDeviceProbe.endMarker)'",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    /// What a script found or did there.
    struct Report: Equatable, Sendable {
        var claude: String?
        var codex: String?
        var launcherInstalled = false
        var helperVersion: String?
        var helperError: String?
        var helperMissing = false
        /// "ok", or why a command failed.
        var claudeResult: String?
        var codexResult: String?
        var launcherError = false

        init(fields: [(key: String, value: String)]) {
            for (key, value) in fields {
                let value = value.trimmingCharacters(in: .whitespaces)
                switch key {
                case "claude": claude = value.nilIfEmpty
                case "codex": codex = value.nilIfEmpty
                case "launcher": launcherInstalled = true
                case "helper_version": helperVersion = value.nilIfEmpty
                case "helper_error": helperError = value.nilIfEmpty ?? "it did not run"
                case "helper_missing": helperMissing = true
                case "claude_result": claudeResult = value
                case "codex_result": codexResult = value
                case "launcher_error": launcherError = true
                default: break
                }
            }
        }

        /// Why the whole did not work, if it did not.
        var failures: [String] {
            var failures: [String] = []
            if launcherError { failures.append("The launcher could not be written.") }
            if let claudeResult, claudeResult != "ok" { failures.append("claude: \(claudeResult)") }
            if let codexResult, codexResult != "ok" { failures.append("codex: \(codexResult)") }
            return failures
        }
    }

    /// Runs `mode`'s script on the device (over its master while it is up).
    static func run(_ mode: Mode, on device: RemoteDevice) async -> Result<Report, HostedSessionError> {
        var shell = await RemoteDeviceShell.app()
        shell.controlPath = HostSSHMasterManager.shared.controlPathIfUp(for: device.sshDestination)
        shell.timeout = 90
        let helper = device.installedResources
            ? RemoteMCPPaths.helperPath(remoteHostPath: device.remoteHostPath, homeDirectory: device.homeDirectory)
            : nil
        let output = await shell.run(script(mode: mode, helperPath: helper), on: device.sshDestination)
        guard let fields = RemoteHostInstaller.fields(output) else {
            if output.status == 255 {
                return .failure(.message(RemoteDeviceSSHFailure.classify(output.standardError).message))
            }
            return .failure(.message(output.standardError.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? "The script did not run on \(device.name) (exit \(output.status))."))
        }
        return .success(Report(fields: fields))
    }
}

// MARK: - The sheet

@MainActor
final class RemoteMCPSetupModel: ObservableObject {
    let deviceID: UUID
    let store: RemoteDeviceStore
    typealias Runner = @MainActor (RemoteMCPSetup.Mode, RemoteDevice) async -> Result<RemoteMCPSetup.Report, HostedSessionError>
    private let runner: Runner

    @Published private(set) var report: RemoteMCPSetup.Report?
    @Published private(set) var isRunning = false
    @Published private(set) var error: String?
    /// What the last confirmed action did.
    @Published private(set) var done: RemoteMCPSetup.Mode?

    init(deviceID: UUID, store: RemoteDeviceStore, runner: @escaping Runner = { await RemoteMCPSetup.run($0, on: $1) }) {
        self.deviceID = deviceID
        self.store = store
        self.runner = runner
    }

    var device: RemoteDevice? { store.device(id: deviceID) }

    /// The forward's state, when the app made one.
    var forwardSummary: String {
        switch RemoteMCPForwards.existing?.states[deviceID] {
        case .up?: "Cherry's control socket is forwarded to \(device?.name ?? "it") now."
        case .making?: "Cherry's control socket is being forwarded to \(device?.name ?? "it")."
        case .failed(let reason)?: reason
        case nil: "Cherry forwards its control socket there while it is connected to \(device?.name ?? "it")."
        }
    }

    func check() async { await perform(.check) }

    func perform(_ mode: RemoteMCPSetup.Mode) async {
        guard let device, !isRunning else { return }
        isRunning = true
        error = nil
        defer { isRunning = false }
        switch await runner(mode, device) {
        case .success(let report):
            self.report = report
            if mode != .check {
                done = mode
                let failures = report.failures
                if !failures.isEmpty { error = failures.joined(separator: "\n") }
            }
        case .failure(let failure):
            error = failure.localizedDescription
        }
    }

    /// Lines saying what was found there.
    var findings: [String] {
        guard let report, let device else { return [] }
        var lines: [String] = []
        lines.append(report.claude.map { "Claude Code: \($0)" } ?? "Claude Code: not found on \(device.name)")
        lines.append(report.codex.map { "Codex: \($0)" } ?? "Codex: not found on \(device.name)")
        if let version = report.helperVersion {
            lines.append("CherryMCP runs there (\(version)).")
        } else if let helperError = report.helperError {
            lines.append("CherryMCP does not run on \(device.name): \(helperError)")
        } else if report.helperMissing || !device.installedResources {
            lines.append("This Cherry's CherryMCP is not installed there: use Update Session Host… first.")
        }
        return lines
    }

    var canSetUp: Bool {
        guard let report, !isRunning else { return false }
        return report.claude != nil || report.codex != nil
    }
}

struct RemoteMCPSetupSheet: View {
    @StateObject var model: RemoteMCPSetupModel
    let close: () -> Void

    var body: some View {
        let name = model.device?.name ?? "Mac"
        VStack(alignment: .leading, spacing: 12) {
            Text("Set Up Cherry MCP on \(name)").font(.title2.weight(.semibold))
            Text("Agents that run in this Cherry's tabs on \(name) can use Cherry's MCP tools, scoped to their window as on this Mac. Claude Code and Codex there read their MCP servers from their own settings on \(name): Set Up runs these commands there.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(RemoteMCPSetup.commands(mode: .install).joined(separator: "\n"))
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.secondary.opacity(0.1)))
            if model.isRunning, model.report == nil {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Checking \(name)…").foregroundStyle(.secondary)
                }
            }
            ForEach(Array(model.findings.enumerated()), id: \.offset) { _, line in
                Text(line).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
            }
            Text(model.forwardSummary).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let done = model.done, model.error == nil {
                Label(
                    done == .remove
                        ? "Removed Cherry MCP from the agents on \(name)."
                        : "Claude Code and Codex on \(name) now start Cherry MCP (in new agent sessions).",
                    systemImage: "checkmark.circle.fill"
                )
                .foregroundStyle(.green)
            }
            if let error = model.error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                if model.isRunning, model.report != nil { ProgressView().controlSize(.small) }
                Button("Remove") { Task { await model.perform(.remove) } }
                    .disabled(!model.canSetUp)
                Spacer()
                Button(model.done == nil ? "Cancel" : "Done") { close() }
                    .keyboardShortcut(.cancelAction)
                Button("Set Up") { Task { await model.perform(.install) } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canSetUp)
            }
        }
        .padding(20)
        .frame(width: 560)
        .task { await model.check() }
    }
}

/// Shows Set Up Cherry MCP… for a device as a sheet on the key window (the
/// device menu, Settings › Sessions › Other Macs).
@MainActor
enum RemoteMCPSetupPresenter {
    static func present(deviceID: UUID, store: RemoteDeviceStore = .shared) {
        guard store.device(id: deviceID) != nil else { return }
        let panel = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 560, height: 320),
            styleMask: [.titled], backing: .buffered, defer: true
        )
        weak let weakPanel = panel
        let close = {
            guard let panel = weakPanel else { return }
            if let parent = panel.sheetParent { parent.endSheet(panel) } else { panel.close() }
        }
        panel.contentViewController = NSHostingController(
            rootView: RemoteMCPSetupSheet(model: RemoteMCPSetupModel(deviceID: deviceID, store: store), close: close)
        )
        if let parent = NSApp.keyWindow ?? NSApp.mainWindow {
            parent.beginSheet(panel)
        } else {
            panel.center()
            panel.makeKeyAndOrderFront(nil)
        }
    }
}
