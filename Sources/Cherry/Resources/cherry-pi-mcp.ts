// Cherry MCP for a Pi agent that Cherry starts (`pi … -e <this file>`).
// Registers Cherry's stdio server for this Pi session only: nothing is written
// to Pi's settings. A server of the same name in Pi's mcp.json takes
// precedence over it (Settings › Agents › Pi says when that one is stale).
// Cherry sets CHERRY_MCP_HELPER (its CherryMCP) and CHERRY_MCP_SERVER_NAME in
// the tab; Pi passes its whole environment on to the server, so CherryMCP sees
// the tab's CHERRY_* variables.
// Plain JavaScript, no imports: Pi loads it with jiti, and Cherry's tests run
// it in JavaScriptCore.
export default function cherryMCP(pi) {
  const env = (typeof process === "object" && process && process.env) || {};
  const helper = env.CHERRY_MCP_HELPER;
  const name = env.CHERRY_MCP_SERVER_NAME || "cherry";
  // A Pi without MCP (before 0.99) loads this and does nothing.
  if (!pi || typeof pi.registerMcpServer !== "function") return;
  if (typeof helper !== "string" || !helper.startsWith("/")) return;
  if (!/^[A-Za-z0-9_-]+$/.test(name)) return;
  pi.registerMcpServer(name, {
    command: helper,
    args: ["--client-tool-timeout", "300"],
    exposure: "deferred",
    timeout: 300,
    description:
      "Cherry, the terminal app this Pi runs in: its tabs, agents, Cherry tasks (get_my_task, report_result), waits and ports. Load its tools with tool_search.",
  });
}
