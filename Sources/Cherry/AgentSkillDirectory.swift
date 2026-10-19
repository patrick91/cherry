import CherryControl
import Foundation
import os

/// The `cherry` skill the agents Cherry starts get for their launch
/// (docs/specs/agent-cli.md, Teaching agents), written by the app into its
/// own `<identity's Application Support>/agent-skill`:
///
///     cherry-plugin/.claude-plugin/plugin.json   Claude Code's --plugin-dir
///     cherry-plugin/skills/cherry/SKILL.md       Pi's --skill (the directory)
///
/// From `CherryAgentSkill`, which `cherry skill show --skill-md` prints, so
/// the two never differ; nothing is written to an agent's configuration.
/// It is not a bundle resource: SwiftPM's `.process` flattens a resource
/// directory, and Claude Code's plugin layout needs the directories.
enum AgentSkillDirectory {
    private static let storage = OSAllocatedUnfairLock<URL?>(initialState: nil)

    /// The plugin directory launches use, once the app prepared it
    /// (`prepare`). Nil in tests and when it could not be written or read.
    static var current: URL? {
        get { storage.withLock { $0 } }
        set { storage.withLock { $0 = newValue } }
    }

    /// `<identity's Application Support>/agent-skill/cherry-plugin`.
    static func pluginDirectory(homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        CherryAppIdentity.applicationSupportDirectory(homeDirectory: homeDirectory)
            .appendingPathComponent("agent-skill", isDirectory: true)
            .appendingPathComponent("cherry-plugin", isDirectory: true)
    }

    /// The skill's own directory inside a plugin directory (Pi's `--skill`).
    static func skillDirectory(inPlugin plugin: URL) -> URL {
        plugin.appendingPathComponent("skills", isDirectory: true)
            .appendingPathComponent(CherryAgentSkill.name, isDirectory: true)
    }

    /// The files and their contents, relative to the plugin directory.
    static let files: [(path: String, contents: String)] = [
        (".claude-plugin/plugin.json", CherryAgentSkill.pluginManifest),
        ("skills/\(CherryAgentSkill.name)/SKILL.md", CherryAgentSkill.markdown + "\n"),
    ]

    /// Writes the files under `plugin` (only when `canWrite`: the
    /// instance-lock holder; a file already right is left alone) and
    /// returns `plugin` when every file there has this build's contents,
    /// else nil: a launch then gives no skill, and an agent without it
    /// still has `cherry skill show`.
    static func prepare(plugin: URL, canWrite: Bool, fileManager: FileManager = .default) -> URL? {
        var ready = true
        for file in files {
            let url = plugin.appendingPathComponent(file.path, isDirectory: false)
            let data = Data(file.contents.utf8)
            if (try? Data(contentsOf: url)) == data { continue }
            guard canWrite else {
                ready = false
                continue
            }
            do {
                try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try data.write(to: url, options: .atomic)
            } catch {
                ready = false
            }
        }
        return ready ? plugin : nil
    }
}
