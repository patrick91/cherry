import Foundation

/// The `cherry` skill (docs/specs/agent-cli.md, Teaching agents): a short
/// SKILL.md that points at `cherry skill show`, so an agent always reads the
/// guide of the `cherry` it runs. `cherry skill show --skill-md` prints it,
/// `cherry skill setup` installs it, and the app gives it to the agents it
/// starts as a Claude Code plugin and a Pi skill (`AgentSkillDirectory`).
public enum CherryAgentSkill {
    /// The skill's name, its directory's (`skills/cherry`) and the plugin's.
    public static let name = "cherry"

    /// SKILL.md. The description is quoted, so YAML never reads a colon in
    /// it as a map.
    public static let markdown = """
    ---
    name: cherry
    description: "Use when running inside Cherry (INSIDE_CHERRY=1) or when asked to work with Cherry tabs, agents, workers, tasks, terminals, commands or todos. The cherry command opens, reads, messages and waits for them."
    ---

    # Cherry

    You run in a tab of Cherry, a terminal app for agents. The `cherry` command
    lists, reads, messages and starts its tabs, runs workers and their tasks,
    and keeps the project's todos.

    - Without an ID a command acts on your own tab; a tab's name works as its ID.
    - Long text goes on standard input: `cherry send ID <<'EOF'` … `EOF`.
    - If your tab got a Cherry task kickoff, run `cherry task mine` first and
      finish with `cherry task report`.

    Run `cherry skill show` for the full guide before your first other `cherry` command.
    """

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
