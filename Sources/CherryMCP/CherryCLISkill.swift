import CherryControl
import Foundation

// `cherry skill setup|status|remove` (CherrySkillInstaller): run by hand, so
// the command is the user's consent; `--dry-run` only says what it would do.

extension CherryCLIRunner {
    /// The installer for `request`: this process's environment, the
    /// repository of the working directory with `--project`.
    public static func installer(for request: CherrySkillRequest) -> CherrySkillInstaller {
        let root = request.project
            ? CherrySkillEnvironment.projectRoot(from: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            : nil
        return CherrySkillInstaller(environment: .current(projectRoot: root))
    }

    /// Runs `request`: a table, or JSON (`{"items": …}` for status,
    /// `{"changes": …, "dry_run": …}` otherwise). Exit 1 when a change
    /// failed.
    static func runSkill(_ request: CherrySkillRequest, installer: CherrySkillInstaller, json: Bool) -> Outcome {
        switch request.operation {
        case .status:
            let items = installer.items(for: request.agents)
            let text = json ? encode(SkillStatusPayload(items: items)) : statusTable(items)
            return Outcome(standardOutput: text + "\n", standardError: "", exitCode: 0)
        case .setup, .remove:
            let changes = request.operation == .setup
                ? installer.setup(agents: request.agents, force: request.force, dryRun: request.dryRun)
                : installer.remove(agents: request.agents, dryRun: request.dryRun)
            let text = json ? encode(SkillChangesPayload(changes: changes, dryRun: request.dryRun)) : changesTable(changes)
            let failed = changes.contains(where: \.failed)
            return Outcome(standardOutput: text + "\n", standardError: "", exitCode: failed ? 1 : 0)
        }
    }

    struct SkillStatusPayload: Encodable {
        var items: [CherrySkillItem]
    }

    struct SkillChangesPayload: Encodable {
        var changes: [CherrySkillChange]
        var dryRun: Bool

        enum CodingKeys: String, CodingKey {
            case changes
            case dryRun = "dry_run"
        }
    }

    static func encode(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }

    static func agentsCell(_ item: CherrySkillItem) -> String {
        let agents = item.agents.isEmpty ? item.target.agents : item.agents
        return agents.map(\.displayName).joined(separator: ", ")
    }

    static func statusTable(_ items: [CherrySkillItem]) -> String {
        textTable(
            ["WHAT", "FOR", "STATUS", "PATH"],
            items.map { item in
                [item.target.title, agentsCell(item), item.status.rawValue + (item.detail.map { " (\($0))" } ?? ""), item.path]
            }
        )
    }

    static func changesTable(_ changes: [CherrySkillChange]) -> String {
        textTable(
            ["WHAT", "FOR", "CHANGE", "PATH"],
            changes.map { change in
                [
                    change.item.target.title, agentsCell(change.item),
                    change.change.rawValue.replacingOccurrences(of: "_", with: " ") + (change.detail.map { " (\($0))" } ?? ""),
                    change.item.path,
                ]
            }
        )
    }

    static func textTable(_ header: [String], _ rows: [[String]]) -> String {
        let widths = header.indices.map { column in
            ([header[column]] + rows.map { $0[column] }).map(\.count).max() ?? 0
        }
        func line(_ cells: [String]) -> String {
            zip(cells, widths).map { $0.padding(toLength: $1, withPad: " ", startingAt: 0) }
                .joined(separator: "  ").trimmingCharacters(in: .whitespaces)
        }
        return ([line(header)] + rows.map(line)).joined(separator: "\n")
    }
}
