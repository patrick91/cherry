import Foundation

/// The Pi extension Cherry gives the Pi agents it starts (`pi … -e <it>`,
/// `AgentMCPLaunch`): `Resources/cherry-pi-mcp.ts`, which registers Cherry's
/// stdio server (the tab's `CHERRY_MCP_HELPER`, named `CHERRY_MCP_SERVER_NAME`)
/// for that Pi session only, with deferred exposure but for the task tools
/// (`spawn_agent`, `wait_for_tasks`, `get_task`, `get_my_task`,
/// `report_result`: direct, in its `toolExposure`), a 300 s timeout and
/// `PiMCPRegistration.serverDescription`, and adds a `cherry_workers`
/// section to each prompt's system prompt (`before_agent_start`) on running
/// workers and being one, while Pi lists the task tools declared or
/// deferred (`pi.getAllTools()`). Nothing is written to Pi's settings, and a server
/// of the same name in Pi's `mcp.json` takes precedence over it. A Pi
/// without MCP loads it and does nothing.
///
/// SwiftPM copies it flat into `Cherry_Cherry.bundle`, which the app keeps
/// in `Contents/Resources`, sealed with its other resources (never in
/// `Contents/MacOS`). A device's install carries a copy next to its
/// CherryMCP (`RemoteHostHelpers.piExtension`, `RemoteMCPPaths.piExtensionPath`).
enum PiMCPExtension {
    /// Its name, in the bundle and in a device's install.
    static let fileName = "cherry-pi-mcp.ts"

    /// The bundle's copy, when it can be read.
    static var bundledURL: URL? {
        guard let url = CherryResources.bundle.url(forResource: "cherry-pi-mcp", withExtension: "ts"),
              FileManager.default.isReadableFile(atPath: url.path)
        else { return nil }
        return url
    }

    /// The bundle's copy's path: the app's `AgentMCPLaunchContext.piExtensionPath`.
    static var bundledPath: String? {
        bundledURL?.path
    }
}
