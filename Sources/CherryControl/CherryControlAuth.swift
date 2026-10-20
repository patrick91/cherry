import Darwin
import Foundation

// The `cherry` command for agents on another Mac
// (docs/specs/remote-devices.md, phase 4b). A tab Cherry runs on another Mac (a device) gets a capability token
// for that tab in its environment, and the path of the app's control socket
// forwarded there over SSH. Its `cherry` presents the token with every
// request (`CherryControlEnvelope`): the app's control server identifies a
// caller that comes through a forward by its token, never by process id
// (its processes are another Mac's).

extension CherryControl {
    /// The tab's capability token (hex, 256 bits), in the environment of a
    /// tab Cherry runs on another Mac.
    public static let mcpTokenEnvironmentKey = "CHERRY_MCP_TOKEN"
    /// What Cherry's tabs had before `cherry` sent its agent commands to the
    /// app itself: the CherryMCP helper it ran, and the name of its MCP
    /// server. No tab gets them now; an inherited one is dropped
    /// (`CherryTabEnvironment.keys`).
    public static let mcpHelperEnvironmentKey = "CHERRY_MCP_HELPER"
    public static let mcpServerNameEnvironmentKey = "CHERRY_MCP_SERVER_NAME"
    /// The name of the Mac Cherry runs on, for "Cherry on <Mac> is not
    /// reachable".
    public static let controlMachineEnvironmentKey = "CHERRY_CONTROL_MACHINE"

    /// The Cherry variables a tab of another Mac carries, which its
    /// `cherry` needs. (Reading them from an ancestor does not work: macOS
    /// does not show another process's environment.)
    public static let remoteTabEnvironmentKeys: [String] = [
        mcpTokenEnvironmentKey,
        socketEnvironmentKey,
        processIDEnvironmentKey,
        agentIDEnvironmentKey,
        projectRootEnvironmentKey,
        controlMachineEnvironmentKey,
    ]
}

/// What a caller on another Mac presents: its tab's id and token.
public struct CherryControlCredentials: Codable, Equatable, Sendable {
    public let token: String
    public let processID: String

    public init(token: String, processID: String) {
        self.token = token
        self.processID = processID
    }

    /// The token and tab id of a tab of another Mac, when the environment
    /// has both.
    public static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> CherryControlCredentials? {
        guard let token = environment[CherryControl.mcpTokenEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty,
            let processID = (environment[CherryControl.processIDEnvironmentKey] ?? environment[CherryControl.agentIDEnvironmentKey])?
            .trimmingCharacters(in: .whitespacesAndNewlines), !processID.isEmpty
        else { return nil }
        return CherryControlCredentials(token: token, processID: processID)
    }
}

/// A request with its caller's credentials: the one line an authenticated
/// connection sends (the handshake and the request together, since every
/// control connection carries one request).
public struct CherryControlEnvelope: Codable, Equatable, Sendable {
    public let cherryAuth: CherryControlCredentials
    public let request: CherryControlRequest

    public init(cherryAuth: CherryControlCredentials, request: CherryControlRequest) {
        self.cherryAuth = cherryAuth
        self.request = request
    }

    /// A request line: an envelope, or a plain request (nil credentials).
    public static func decode(_ data: Data) throws -> (credentials: CherryControlCredentials?, request: CherryControlRequest) {
        let decoder = JSONDecoder()
        if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any], object["cherryAuth"] != nil {
            let envelope = try decoder.decode(CherryControlEnvelope.self, from: data)
            return (envelope.cherryAuth, envelope.request)
        }
        return (nil, try decoder.decode(CherryControlRequest.self, from: data))
    }
}
