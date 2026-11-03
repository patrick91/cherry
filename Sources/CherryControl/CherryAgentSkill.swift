import Foundation

/// The `cherry` skill (docs/specs/agent-cli.md, Teaching agents): a short
/// SKILL.md that points at `cherry skill show`, so an agent always reads the
/// guide of the `cherry` it runs. `cherry skill show --skill-md` prints it,
/// `cherry skill setup` installs it, and the app gives it to the agents it
/// starts as a Claude Code plugin and a Pi skill (`AgentSkillDirectory`).
public enum CherryAgentSkill {
    /// The skill's name, its directory's (`skills/cherry`) and the plugin's.
    public static let name = "cherry"

    /// SKILL.md: `CherrySkill.markdown`, the text `cherry skill setup`
    /// installs, so a launch and an install give agents the same skill.
    public static var markdown: String { CherrySkill.markdown }

    /// The Claude Code plugin's manifest (`.claude-plugin/plugin.json`):
    /// its name, which namespaces the skill (`cherry:cherry`), a version and
    /// a description.
    public static let pluginManifest = """
    {
      "description": "Cherry's cherry command: its tabs, agents, workers and tasks.",
      "name": "cherry",
      "version": "1.0.0"
    }

    """
}
