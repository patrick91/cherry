import CherryControl
import Foundation
@testable import Cherry

// A tool call as a caller sends it over the control socket (`callTool`),
// for tests that drive a private server: what CherryMCP's session did
// before `cherry` sent its commands to the app itself. The socket and the
// caller come from the process environment, which those tests set around
// each call.

/// A caller and the process it is bound to (`bind_session_process`), for
/// the calls made with it.
final class ToolCallBinding: @unchecked Sendable {
    let callerProcessID: String?
    private let lock = NSLock()
    private var storedBoundProcessID: String?

    var boundProcessID: String? {
        lock.withLock { storedBoundProcessID }
    }

    private init(callerProcessID: String?) {
        self.callerProcessID = callerProcessID
        storedBoundProcessID = callerProcessID
    }

    static func bound(callerProcessID: String? = nil) -> ToolCallBinding {
        ToolCallBinding(callerProcessID: callerProcessID)
    }

    func bindProcessID(_ processID: String) {
        lock.withLock { storedBoundProcessID = processID }
    }
}

enum ToolCalls {
    /// Runs `name` as the environment's tab (or `binding`'s caller), its
    /// project the environment's CHERRY_PROJECT_ROOT, its directory the
    /// current one; over `socketURL` as This Mac's caller when given, else
    /// the environment's socket and credentials.
    static func call(
        name: String,
        arguments: [String: JSONValue],
        context binding: ToolCallBinding? = nil,
        socketURL: URL? = nil
    ) async -> CallToolResult {
        let environment = ProcessInfo.processInfo.environment
        let context = ToolCallContext(
            callerProcessID: binding?.callerProcessID ?? (binding == nil ? environmentProcessID() : nil),
            boundProcessID: binding?.boundProcessID,
            bindsSession: binding != nil,
            projectRoot: environment[CherryControl.projectRootEnvironmentKey],
            workingDirectory: FileManager.default.currentDirectoryPath,
            profile: ToolClientProfile(client: nil, toolTimeoutMilliseconds: nil),
            interface: "cli"
        )
        let request = CherryControlRequest.callTool(.init(name: name, arguments: arguments, context: context))
        let timeout = CherryToolLayer.callTimeout(for: name, arguments: arguments, profile: .unknown)
        let result: CallToolResult
        do {
            let transport = socketURL.map { SocketToolTransport(socketURL: $0, credentials: nil, controlMachine: nil) } ?? SocketToolTransport()
            let response = try await transport.send(request, timeout: timeout)
            if let error = response.error {
                return CherryToolLayer.errorResult(error)
            }
            guard case .callTool(let answer)? = response.result else {
                return CherryToolLayer.errorResult(.init(code: "unexpected_response", message: "Cherry returned an unexpected response for callTool."))
            }
            result = answer
        } catch {
            return CherryToolLayer.errorResult(CherryToolLayer.controlError(error))
        }
        if let bindProcessID = result.bindProcessID {
            binding?.bindProcessID(bindProcessID)
        }
        return result
    }

    /// The tab the environment names (CHERRY_PROCESS_ID, else
    /// CHERRY_AGENT_ID), when it is a UUID.
    static func environmentProcessID() -> String? {
        let environment = ProcessInfo.processInfo.environment
        let value = environment[CherryControl.processIDEnvironmentKey] ?? environment[CherryControl.agentIDEnvironmentKey]
        guard let processID = value?.trimmingCharacters(in: .whitespacesAndNewlines), UUID(uuidString: processID) != nil else {
            return nil
        }
        return processID
    }

    /// The tab whose program one of `parentPIDs` is, as the tool layer
    /// finds it.
    static func inferredCallerProcessID(parentPIDs: [Int32]) async -> String? {
        await CherryToolLayer.inferredCallerProcessID(
            parentPIDs: parentPIDs,
            caller: CherryToolCaller(
                processID: environmentProcessID(),
                projectRoot: ProcessInfo.processInfo.environment[CherryControl.projectRootEnvironmentKey],
                workingDirectory: FileManager.default.currentDirectoryPath
            ),
            transport: SocketToolTransport()
        )
    }
}

/// The Rust `cherry` `Scripts/build-host debug` made: in CARGO_TARGET_DIR
/// (when set and not empty), else Host/target.
func builtCherryCLI() throws -> URL {
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let target = ProcessInfo.processInfo.environment["CARGO_TARGET_DIR"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
        ?? repository.appendingPathComponent("Host/target")
    let cli = target.appendingPathComponent("debug/cherry")
    guard FileManager.default.isExecutableFile(atPath: cli.path) else {
        throw HostedSessionError.message("Build cherry first: Scripts/build-host debug (looked for \(cli.path))")
    }
    return cli
}

/// Runs `cherry ARGUMENTS…` with exactly `environment`, `input` on its
/// standard input (else /dev/null): its exit status, standard output and
/// standard error.
func runCherryCLI(
    _ cli: URL,
    _ arguments: [String],
    environment: [String: String],
    input: String? = nil,
    workingDirectory: URL? = nil
) async throws -> (status: Int32, output: String, error: String) {
    try await Task.detached {
        let process = Process()
        process.executableURL = cli
        process.arguments = arguments
        process.environment = environment
        if let workingDirectory { process.currentDirectoryURL = workingDirectory }
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        let stdin = input.map { _ in Pipe() }
        process.standardInput = stdin ?? FileHandle.nullDevice
        try process.run()
        if let stdin, let input {
            stdin.fileHandleForWriting.write(Data(input.utf8))
            try? stdin.fileHandleForWriting.close()
        }
        let errorData = Task.detached { error.fileHandleForReading.readDataToEndOfFile() }
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self), String(decoding: await errorData.value, as: UTF8.self))
    }.value
}
