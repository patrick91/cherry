import CherryControl
import Darwin
import Foundation
import MCP
import Testing

@testable import Cherry
@testable import CherryMCP

// CherryMCP as a pipe (control protocol 2): its `tools/list` is the app's
// `listTools` for the client its `initialize` names, each `tools/call` one
// `callTool`, and a new digest in a call's answer sends
// `notifications/tools/list_changed`. Against an app that predates
// `appInfo` it runs the tool layer itself over typed requests (legacy).
// Sessions get their environment injected (the control socket of a test
// server, `PipeTestApp` or `ControlServerHarness`), never the process's.

// MARK: - Helpers

/// The CherryMCP `swift build` made.
private func pipeBuiltCherryMCP() throws -> URL {
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let helper = repository.appendingPathComponent(".build/debug/CherryMCP")
    try #require(FileManager.default.isExecutableFile(atPath: helper.path), "Build CherryMCP first: swift build --build-tests")
    return helper
}

/// A directory under /tmp that only this user may enter, as a control
/// socket's must be.
private func pipePrivateDirectory() throws -> URL {
    let directory = URL(fileURLWithPath: "/tmp/cherry-pipe-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try #require(chmod(directory.path, 0o700) == 0)
    return directory
}

private let pipeClaudeProfile = ToolClientProfile(client: ToolClientInfo(name: "claude-code", version: "2.1.299"))

private func pipeErrorCode(_ result: CallToolResult) -> String? {
    guard result.isError else { return nil }
    return result.structured?.objectValue?["error"]?.objectValue?["code"]?.stringValue
}

private func pipeObject(_ text: String) -> [String: JSONValue] {
    (try? JSONValue.parse(Data(text.utf8)))?.objectValue ?? [:]
}

/// MCP requests as a client writes them.
private func pipeInitialize(id: Int, client: String, version: String) -> String {
    #"{"jsonrpc":"2.0","id":\#(id),"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"\#(client)","version":"\#(version)"}}}"#
}

private let pipeInitialized = #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#

private func pipeToolsList(id: Int) -> String {
    #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/list"}"#
}

private func pipeToolsCall(id: Int, name: String) -> String {
    #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"\#(name)","arguments":{}}}"#
}

/// Runs the built CherryMCP with exactly `environment`, in `directory`.
private func pipeRun(
    _ helper: URL,
    _ arguments: [String],
    environment: [String: String],
    directory: URL? = nil
) async throws -> (status: Int32, output: String, errors: String) {
    try await Task.detached {
        let process = Process()
        process.executableURL = helper
        process.arguments = arguments
        process.environment = environment
        if let directory { process.currentDirectoryURL = directory }
        let output = Pipe()
        let errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let outputData = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: outputData, as: UTF8.self), String(decoding: errorData, as: UTF8.self))
    }.value
}

/// An MCP client's end of CherryMCP's standard input and output, served by
/// a session in this process (`CherryMCPSession.serve`). Reads never block
/// the main actor, where a test's control server answers.
private final class PipeStdio: @unchecked Sendable {
    private let input: [Int32]
    private let output: [Int32]
    private var buffered = Data()
    /// Responses read while waiting for another one: they may come in any
    /// order.
    private var unclaimed: [[String: JSONValue]] = []

    init() throws {
        var input = [Int32](repeating: 0, count: 2)
        var output = [Int32](repeating: 0, count: 2)
        guard pipe(&input) == 0, pipe(&output) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        self.input = input
        self.output = output
    }

    /// The server's side: it reads what the client writes.
    func serverTransport() -> CherryStdioTransport {
        CherryStdioTransport(inputFileDescriptor: input[0], outputFileDescriptor: output[1])
    }

    /// `messages`, one per line, in one write.
    func send(_ messages: [String]) throws {
        let data = Data((messages.joined(separator: "\n") + "\n").utf8)
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(input[1], buffer.baseAddress!.advanced(by: offset), data.count - offset)
                if count > 0 {
                    offset += count
                } else if count < 0, errno == EINTR {
                    continue
                } else {
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
            }
        }
    }

    /// The response to request `id`, and the notifications read while
    /// waiting for it.
    func response(id: Int, seconds: Double = 10) async throws -> (response: [String: JSONValue], before: [[String: JSONValue]]) {
        if let index = unclaimed.firstIndex(where: { $0["id"] == .int(id) }) {
            return (unclaimed.remove(at: index), [])
        }
        let deadline = Date().addingTimeInterval(seconds)
        var before: [[String: JSONValue]] = []
        while Date() < deadline {
            let line = try await nextLine(until: deadline)
            let message = try JSONValue.parse(line).objectValue ?? [:]
            if message["id"] == .int(id) {
                return (message, before)
            }
            if message["id"] == nil {
                before.append(message)
            } else {
                unclaimed.append(message)
            }
        }
        throw POSIXError(.ETIMEDOUT)
    }

    private func nextLine(until deadline: Date) async throws -> Data {
        while true {
            if let newline = buffered.firstIndex(of: 0x0A) {
                let line = buffered[buffered.startIndex..<newline]
                buffered = Data(buffered[buffered.index(after: newline)...])
                return Data(line)
            }
            let milliseconds = Int32(max(deadline.timeIntervalSinceNow * 1_000, 1))
            let chunk = try await readAvailable(timeoutMilliseconds: milliseconds)
            guard !chunk.isEmpty else { throw POSIXError(.EPIPE) }
            buffered.append(chunk)
        }
    }

    private func readAvailable(timeoutMilliseconds: Int32) async throws -> Data {
        let descriptor = output[0]
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                var poll = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
                guard Darwin.poll(&poll, 1, timeoutMilliseconds) > 0 else {
                    continuation.resume(throwing: POSIXError(.ETIMEDOUT))
                    return
                }
                var bytes = [UInt8](repeating: 0, count: 65_536)
                let count = Darwin.read(descriptor, &bytes, bytes.count)
                guard count >= 0 else {
                    continuation.resume(throwing: POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO))
                    return
                }
                continuation.resume(returning: Data(bytes.prefix(count)))
            }
        }
    }

    func close() {
        (input + output).forEach { _ = Darwin.close($0) }
    }
}

/// A control socket that records each request and answers it with
/// `answer` (given the request and those before it): an app of any
/// control protocol, as CherryMCP sees it.
private final class PipeTestApp: @unchecked Sendable {
    let directory: URL
    let socketURL: URL
    private let listener: Int32
    private let answer: @Sendable (CherryControlRequest, [CherryControlRequest]) -> CherryControlResponse
    private let lock = NSLock()
    private var received: [CherryControlRequest] = []
    private var isStopped = false
    private let finished = DispatchSemaphore(value: 0)

    init(answer: @escaping @Sendable (CherryControlRequest, [CherryControlRequest]) -> CherryControlResponse) throws {
        self.answer = answer
        directory = try pipePrivateDirectory()
        socketURL = directory.appendingPathComponent("control.sock")
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(listener >= 0)
        let bound = UnixIO.withSocketAddress(path: socketURL.path) { Darwin.bind(listener, $0, $1) }
        try #require(bound == 0 && listen(listener, 16) == 0)
        Thread.detachNewThread { [self] in serve() }
    }

    /// Every request so far, in the order they came.
    var requests: [CherryControlRequest] {
        lock.withLock { received }
    }

    var environment: [String: String] {
        [CherryControl.socketEnvironmentKey: socketURL.path]
    }

    func stop() {
        lock.withLock { isStopped = true }
        finished.wait()
        try? FileManager.default.removeItem(at: directory)
    }

    private func serve() {
        while !lock.withLock({ isStopped }) {
            var poll = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            guard Darwin.poll(&poll, 1, 50) > 0 else { continue }
            let connection = accept(listener, nil, nil)
            guard connection >= 0 else { continue }
            UnixIO.setNoSigPipe(connection)
            respond(on: connection)
            Darwin.close(connection)
        }
        Darwin.close(listener)
        finished.signal()
    }

    private func respond(on connection: Int32) {
        var line = Data()
        var bytes = [UInt8](repeating: 0, count: 4_096)
        while line.last != 0x0A {
            let count = Darwin.read(connection, &bytes, bytes.count)
            guard count > 0 else { break }
            line.append(contentsOf: bytes.prefix(count))
        }
        guard let request = try? CherryControlEnvelope.decode(line.filter { $0 != 0x0A }).request else { return }
        let before = lock.withLock {
            defer { received.append(request) }
            return received
        }
        guard let encoded = try? JSONEncoder().encode(answer(request, before)) else { return }
        let reply = encoded + Data([0x0A])
        _ = reply.withUnsafeBytes { Darwin.write(connection, $0.baseAddress, reply.count) }
    }
}

private let pipeAppInfo = AppInfoResult(
    controlProtocol: 2, build: "20261015120000.abcdef0", version: "2026.10.15.1", bundleIdentifier: "dev.patrick.cherry", urlScheme: "cherry"
)

/// What an app from before control protocol 2 answers a request it cannot
/// decode.
private let pipeCannotDecode = CherryControlResponse(error: .init(code: "invalid_request", message: "The data couldn’t be read because it isn’t in the correct format."))

private func pipeIsToolRequest(_ request: CherryControlRequest) -> Bool {
    switch request {
    case .appInfo, .listTools, .callTool: true
    default: false
    }
}

// MARK: - tools/list

/// An `initialize` and a `tools/list` in one write (a client that does not
/// wait for the first answer): the list is the app's, asked for the client
/// the `initialize` named, though the transport answers `tools/list`
/// itself and the server has not answered the `initialize` yet.
@Test func ControlToolPipeInitializeAndToolsListInOneWriteListTheAppsToolsForThatClient() async throws {
    let only = CherryToolDefinition(
        name: "only_in_this_app",
        description: "A tool only this app has.",
        inputSchema: .object(["type": .string("object"), "properties": .object([:])])
    )
    let app = try PipeTestApp { request, _ in
        switch request {
        case .appInfo: .init(result: .appInfo(pipeAppInfo))
        case .listTools: .init(result: .listTools(.init(tools: [only], digest: "d1d1d1d1d1d1d1d1", instructions: "The app's.")))
        default: .init(error: .init(code: "unexpected", message: "\(request)"))
        }
    }
    defer { app.stop() }
    let stdio = try PipeStdio()
    defer { stdio.close() }
    let session = CherryMCPSession(environment: app.environment, helperExecutableURL: nil)
    let server = try await session.serve(on: stdio.serverTransport())

    try stdio.send([pipeInitialize(id: 1, client: "claude-code", version: "2.1.299"), pipeToolsList(id: 2)])
    let listed = try await stdio.response(id: 2)
    let expected = try JSONValue.parse(CherryToolCatalog.encodedListResult([only]))
    #expect(listed.response["result"] == expected)
    let initialized = try await stdio.response(id: 1)
    let result = initialized.response["result"]?.objectValue ?? [:]
    #expect(result["serverInfo"]?.objectValue?["name"] == .string("cherry"))
    #expect(result["serverInfo"]?.objectValue?["version"] == .string("dev"))
    #expect(result["capabilities"]?.objectValue?["tools"]?.objectValue?["listChanged"] == .bool(true))
    #expect(result["instructions"] == .string(CherryToolCatalog.instructions), "the helper's own instructions")

    #expect(app.requests == [.appInfo, .listTools(.init(profile: pipeClaudeProfile))])
    #expect(await session.profile == pipeClaudeProfile)
    #expect(await session.servedDigest == "d1d1d1d1d1d1d1d1")
    await server.stop()
}

/// Codex 0.162.1's `initialize`, exactly as it sends it: its experimental
/// capability is an object, which the MCP SDK cannot decode (it refused the
/// whole request, -32603, and Codex never connected). It initializes, and
/// its `tools/list` is the app's for Codex.
@Test func ControlToolPipeCodexsInitializeIsAnswered() async throws {
    let app = try PipeTestApp { request, _ in
        switch request {
        case .appInfo: .init(result: .appInfo(pipeAppInfo))
        case .listTools(let list): .init(result: .listTools(CherryToolCatalog.listResult(for: list.profile ?? .unknown)))
        default: .init(error: .init(code: "unexpected", message: "\(request)"))
        }
    }
    defer { app.stop() }
    let stdio = try PipeStdio()
    defer { stdio.close() }
    let session = CherryMCPSession(environment: app.environment, arguments: ["--client-tool-timeout", "300"], helperExecutableURL: nil)
    let server = try await session.serve(on: stdio.serverTransport())

    let codexInitialize = #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"experimental":{"codex/auth-change":{}},"elicitation":{"form":{},"url":{}}},"clientInfo":{"name":"codex-mcp-client","title":"Codex","version":"0.162.1"}}}"#
    try stdio.send([codexInitialize])
    let initialized = try await stdio.response(id: 0)
    #expect(initialized.response["error"] == nil, "\(initialized.response)")
    #expect(initialized.response["result"]?.objectValue?["serverInfo"]?.objectValue?["name"] == .string("cherry"))
    try stdio.send([pipeInitialized, #"{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{"_meta":{"progressToken":1}}}"#])
    let listed = try await stdio.response(id: 1)
    let profile = ToolClientProfile(client: ToolClientInfo(name: "codex-mcp-client", version: "0.162.1"), toolTimeoutMilliseconds: 300_000)
    #expect(await session.profile == profile)
    #expect(listed.response["result"] == (try JSONValue.parse(CherryToolCatalog.encodedListResult(CherryToolCatalog.tools(for: profile)))))
    await server.stop()

    // Only an experimental capability the SDK cannot decode is left out;
    // every other message passes as it is.
    let rewritten = try JSONValue.parse(CherryMCPTools.initializeTheSDKDecodes(Data(codexInitialize.utf8)))
    let capabilities = rewritten.objectValue?["params"]?.objectValue?["capabilities"]?.objectValue
    #expect(capabilities?["experimental"] == nil)
    #expect(capabilities?["elicitation"] == .object(["form": .object([:]), "url": .object([:])]))
    #expect(rewritten.objectValue?["id"] == .int(0))
    for unchanged in [
        #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"experimental":{"a":"b"}},"clientInfo":{"name":"x","version":"1"}}}"#,
        pipeInitialize(id: 2, client: "claude-code", version: "2.1.299"),
        #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"x","arguments":{"experimental":{"initialize":{}}}}}"#,
    ] {
        #expect(CherryMCPTools.initializeTheSDKDecodes(Data(unchanged.utf8)) == Data(unchanged.utf8), "\(unchanged)")
    }
}

/// Claude Code's `tools/list` through a real control server is the app's
/// list for Claude Code's profile.
@MainActor
@Test func ControlToolPipeClaudeCodesToolsListIsTheAppsListForItsProfile() async throws {
    let harness = try ControlServerHarness()
    defer { harness.stop() }
    harness.server.start()
    let stdio = try PipeStdio()
    defer { stdio.close() }
    let session = CherryMCPSession(environment: [CherryControl.socketEnvironmentKey: harness.socketURL.path])
    let server = try await session.serve(on: stdio.serverTransport())

    try stdio.send([pipeInitialize(id: 1, client: "claude-code", version: "2.1.299")])
    _ = try await stdio.response(id: 1)
    try stdio.send([pipeInitialized, pipeToolsList(id: 2)])
    let listed = try await stdio.response(id: 2)
    let app = CherryToolCatalog.listResult(for: pipeClaudeProfile)
    #expect(listed.response["result"] == (try JSONValue.parse(CherryToolCatalog.encodedListResult(app.tools))))
    #expect(await session.servedDigest == app.digest)
    #expect(await session.mode == .pipe(CherryControlServer.appInfo()))
    await server.stop()
}

/// No app answers: the list is the helper's own catalog, its waits at most
/// 50 s whatever the client allows (an older app's limit), and a call says
/// Cherry is not running.
@Test func ControlToolPipeWithNoAppListsTheHelpersOwnCatalog() async throws {
    let directory = try pipePrivateDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let environment = [CherryControl.socketEnvironmentKey: directory.appendingPathComponent("none.sock").path]
    let stdio = try PipeStdio()
    defer { stdio.close() }
    let session = CherryMCPSession(environment: environment, arguments: ["--client-tool-timeout", "300"])
    let server = try await session.serve(on: stdio.serverTransport())

    try stdio.send([pipeInitialize(id: 1, client: "codex-mcp-client", version: "0.162.1"), pipeInitialized, pipeToolsList(id: 2)])
    let listed = try await stdio.response(id: 2)
    let profile = ToolClientProfile(client: ToolClientInfo(name: "codex-mcp-client", version: "0.162.1"), toolTimeoutMilliseconds: 300_000)
    #expect(await session.profile == profile)
    #expect(listed.response["result"] == (try JSONValue.parse(CherryToolCatalog.encodedListResult(CherryToolCatalog.tools(for: .unknown)))))
    #expect(await session.servedDigest == CherryToolCatalog.digest(for: .unknown))
    #expect(CherryToolCatalog.digest(for: profile) != CherryToolCatalog.digest(for: .unknown), "a pipe app's list would differ")

    try stdio.send([pipeToolsCall(id: 3, name: "list_processes")])
    let called = try await stdio.response(id: 3)
    let text = called.response["result"]?.objectValue?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue ?? ""
    #expect(called.response["result"]?.objectValue?["isError"] == .bool(true))
    #expect(pipeObject(text)["error"]?.objectValue?["code"] == .string("cherry_unavailable"), "\(text)")
    #expect(await session.mode == .unknown, "a failure to connect never makes the session legacy")

    // get_status still reports the socket, and this helper's build; no mode
    // while no app answers.
    let status = await session.call(name: "get_status", arguments: [:])
    let fields = pipeObject(status.text)
    #expect(!status.isError)
    #expect(fields["cherry_reachable"] == .bool(false))
    #expect(fields["helper_build"] == .string(session.helperBuild))
    #expect(fields["mode"] == nil && fields["app_build"] == nil)
    await server.stop()
}

// MARK: - tools/call

/// An app from before the tool requests (`answersToolRequests` off): the
/// helper runs the tools itself over typed requests, with the same results
/// as the app gives a pipe, and get_status says which.
@MainActor
@Test func ControlToolPipeAnAppWithoutToolRequestsIsServedByTheHelpersOwnLayer() async throws {
    let harness = try ControlServerHarness()
    defer { harness.stop() }
    harness.server.start()
    let environment = [
        CherryControl.socketEnvironmentKey: harness.socketURL.path,
        CherryControl.projectRootEnvironmentKey: harness.projectRoot.path,
    ]
    let pipe = CherryMCPSession(environment: environment)
    let legacy = CherryMCPSession(environment: environment)
    // Each session keeps the mode it found: the switch is set for each call.
    func call(_ session: CherryMCPSession, asOldApp: Bool, _ name: String, _ arguments: [String: JSONValue] = [:]) async -> CallToolResult {
        harness.server.answersToolRequests = !asOldApp
        return await session.call(name: name, arguments: arguments)
    }

    let whoami = await call(pipe, asOldApp: false, "whoami")
    let legacyWhoami = await call(legacy, asOldApp: true, "whoami")
    #expect(!whoami.isError, "\(whoami.text)")
    #expect(whoami.text == legacyWhoami.text)
    #expect(whoami.structured == legacyWhoami.structured)
    #expect(await pipe.mode == .pipe(CherryControlServer.appInfo()))
    guard case .legacy = await legacy.mode else {
        Issue.record("Expected a legacy session, got \(await legacy.mode)")
        return
    }

    let spawned = await call(pipe, asOldApp: false, "spawn_process", ["kind": .string("terminal")])
    let legacySpawned = await call(legacy, asOldApp: true, "spawn_process", ["kind": .string("terminal")])
    let process = spawned.structured?.objectValue?["process"]?.objectValue ?? [:]
    let legacyProcess = legacySpawned.structured?.objectValue?["process"]?.objectValue ?? [:]
    #expect(!spawned.isError && !legacySpawned.isError, "\(spawned.text) \(legacySpawned.text)")
    #expect(Set(spawned.structured?.objectValue?.keys.map { $0 } ?? []) == Set(legacySpawned.structured?.objectValue?.keys.map { $0 } ?? []))
    #expect(process["kind"] == .string("terminal") && legacyProcess["kind"] == .string("terminal"))
    let processID = try #require(process["id"]?.stringValue)
    let legacyProcessID = try #require(legacyProcess["id"]?.stringValue)
    #expect(processID != legacyProcessID)

    let bound = await call(pipe, asOldApp: false, "bind_session_process", ["process_id": .string(processID)])
    let legacyBound = await call(legacy, asOldApp: true, "bind_session_process", ["process_id": .string(legacyProcessID)])
    #expect(pipeObject(bound.text)["bound_process_id"] == .string(processID), "\(bound.text)")
    #expect(pipeObject(legacyBound.text)["bound_process_id"] == .string(legacyProcessID), "\(legacyBound.text)")
    #expect(Set(pipeObject(bound.text).keys) == Set(pipeObject(legacyBound.text).keys))
    #expect(await pipe.boundProcessID == processID)
    #expect(await legacy.boundProcessID == legacyProcessID)

    let status = pipeObject(await call(pipe, asOldApp: false, "get_status").text)
    #expect(status["mode"] == .string("pipe"))
    #expect(status["app_control_protocol"] == .int(CherryControl.controlProtocolVersion))
    #expect(status["app_build"] == .string(CherryControlServer.appInfo().build))
    #expect(status["helper_build"] == .string(pipe.helperBuild))
    #expect(status["cherry_reachable"] == .bool(true))
    let legacyStatus = await call(legacy, asOldApp: true, "get_status")
    #expect(pipeObject(legacyStatus.text)["mode"] == .string("legacy"))
    #expect(pipeObject(legacyStatus.text)["app_build"] == nil)
    #expect(legacyStatus.structured?.objectValue?["mode"] == .string("legacy"))
    #expect(legacyStatus.structured?.objectValue?["helperBuild"] == .string(legacy.helperBuild))
}

/// A session whose environment names no tab (a client that passes no
/// CHERRY_PROCESS_ID, as Codex registered by hand) is bound to the caller
/// the app verified, as CherryMCP bound the caller it found at startup:
/// whoami reports it, the session keeps it, and a bind names it as the
/// previous one.
@MainActor
@Test func ControlToolPipeASessionWithoutAClaimIsBoundToItsVerifiedCaller() async throws {
    let harness = try ControlAgentWaitHarness()
    defer { harness.stop() }
    harness.server.start()
    let lead = try await harness.spawnAgent(named: "Lead")
    let other = try await harness.spawnAgent(named: "Other")
    harness.server.callerSessionResolverForTesting = { _ in lead }
    let session = CherryMCPSession(environment: [
        CherryControl.socketEnvironmentKey: harness.socketURL.path,
        CherryControl.projectRootEnvironmentKey: harness.projectRoot.path,
    ])
    #expect(await session.boundProcessID == nil)

    let whoami = await session.call(name: "whoami", arguments: [:])
    #expect(!whoami.isError, "\(whoami.text)")
    #expect(pipeObject(whoami.text)["caller_process_id"] == .string(lead.id.uuidString), "\(whoami.text)")
    #expect(pipeObject(whoami.text)["bound_process_id"] == .string(lead.id.uuidString), "\(whoami.text)")
    #expect(await session.boundProcessID == lead.id.uuidString)

    let bound = await session.call(name: "bind_session_process", arguments: ["process_id": .string(other.id.uuidString)])
    #expect(pipeObject(bound.text)["previous_bound_process_id"] == .string(lead.id.uuidString), "\(bound.text)")
    #expect(pipeObject(bound.text)["bound_process_id"] == .string(other.id.uuidString), "\(bound.text)")
    #expect(await session.boundProcessID == other.id.uuidString)

    // A single call keeps no binding: nothing is bound for it.
    let single = CherryMCPSession(
        environment: [CherryControl.socketEnvironmentKey: harness.socketURL.path],
        claim: nil, boundProcessID: nil, bindsSession: false, infersCaller: false, workingDirectory: nil
    )
    let once = await single.call(name: "whoami", arguments: [:])
    #expect(pipeObject(once.text)["caller_process_id"] == .string(lead.id.uuidString), "\(once.text)")
    #expect(pipeObject(once.text)["bound_process_id"] == nil, "\(once.text)")
    #expect(once.bindProcessID == nil)
}

/// A string argument that looks like a data URL reaches the app as the
/// client wrote it, though the MCP SDK reads it as data (and would hand the
/// handler a base64 data URL of the same bytes).
@Test func ControlToolPipeADataURLStringArgumentReachesTheAppAsWritten() async throws {
    let answer = CallToolResult(text: "{}", isError: false, structured: .object([:]))
    let app = try PipeTestApp { request, _ in
        switch request {
        case .appInfo: .init(result: .appInfo(pipeAppInfo))
        case .listTools(let list): .init(result: .listTools(CherryToolCatalog.listResult(for: list.profile ?? .unknown)))
        case .callTool: .init(result: .callTool(answer))
        default: .init(error: .init(code: "unexpected", message: "\(request)"))
        }
    }
    defer { app.stop() }
    let stdio = try PipeStdio()
    defer { stdio.close() }
    let session = CherryMCPSession(environment: app.environment, helperExecutableURL: nil)
    let server = try await session.serve(on: stdio.serverTransport())

    try stdio.send([pipeInitialize(id: 1, client: "claude-code", version: "2.1.299")])
    _ = try await stdio.response(id: 1)
    let dataCall = #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"send_process_input","arguments":{"text":"data:,hi","nested":["data:text/plain,a b"],"process_name":"x"}}}"#
    let plainCall = #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"send_process_input","arguments":{"text":"plain","process_name":"x"}}}"#
    // The SDK changes the first one's arguments, not the second's.
    #expect(CherryMCPTools.callArgumentsTheSDKChanges(in: Data(dataCall.utf8))?.written["text"] == .string("data:,hi"))
    #expect(CherryMCPTools.callArgumentsTheSDKChanges(in: Data(plainCall.utf8)) == nil)
    try stdio.send([pipeInitialized, dataCall, plainCall])
    #expect(try await stdio.response(id: 2).response["error"] == nil)
    #expect(try await stdio.response(id: 3).response["error"] == nil)
    let calls = app.requests.compactMap { request -> [String: JSONValue]? in
        guard case .callTool(let call) = request else { return nil }
        return call.arguments
    }
    #expect(calls.count == 2)
    let written = try #require(calls.first { $0["text"] != .string("plain") })
    #expect(written["text"] == .string("data:,hi"))
    #expect(written["nested"] == .array([.string("data:text/plain,a b")]))
    #expect(written["process_name"] == .string("x"))
    #expect(calls.contains { $0["text"] == .string("plain") })
    await server.stop()
}

/// A tool this helper's catalog lacks still goes to the app in pipe mode
/// (a newer app may have it), which answers unknown_tool itself: its
/// answer carries the app's digest.
@MainActor
@Test func ControlToolPipeAToolTheHelperLacksReachesTheApp() async throws {
    let harness = try ControlServerHarness()
    defer { harness.stop() }
    harness.server.start()
    harness.server.toolsDigestOverrideForTesting = "0123456789abcdef"
    let session = CherryMCPSession(environment: [CherryControl.socketEnvironmentKey: harness.socketURL.path])

    let result = await session.call(name: "only_in_a_newer_app", arguments: [:], interface: "call")
    #expect(pipeErrorCode(result) == "unknown_tool", "\(result.text)")
    #expect(result.toolsDigest == "0123456789abcdef", "the app answered it")
}

/// `--call` of a tool only a newer app has: CherryMCP sends it to the app
/// as a callTool of interface "call", with its caller's claim, project and
/// directory, and prints the app's answer.
@Test func ControlToolPipeCallOfAToolOnlyTheAppHasReachesIt() async throws {
    let helper = try pipeBuiltCherryMCP()
    let answer = CallToolResult(text: #"{"error":{"code":"unknown_tool","message":"Unknown Cherry MCP tool: only_in_a_newer_app"}}"#, isError: true, structured: nil)
    let app = try PipeTestApp { request, _ in
        switch request {
        case .appInfo: .init(result: .appInfo(pipeAppInfo))
        case .callTool: .init(result: .callTool(answer))
        default: .init(error: .init(code: "unexpected", message: "\(request)"))
        }
    }
    defer { app.stop() }
    let directory = try pipePrivateDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let tab = UUID().uuidString
    var environment = app.environment
    environment["HOME"] = directory.path
    environment[CherryControl.processIDEnvironmentKey] = tab
    environment[CherryControl.projectRootEnvironmentKey] = "/Users/someone/app"

    let run = try await pipeRun(helper, ["--call", "only_in_a_newer_app", #"{"count":2}"#], environment: environment, directory: directory)
    #expect(run.status == 1, "\(run.output) \(run.errors)")
    #expect(run.output == answer.text + "\n")
    let requests = app.requests
    #expect(requests.count == 2 && requests.first == .appInfo)
    guard case .callTool(let call)? = requests.last else {
        Issue.record("Expected a callTool, got \(requests)")
        return
    }
    #expect(call.name == "only_in_a_newer_app")
    #expect(call.arguments == ["count": .int(2)])
    let context = try #require(call.context)
    #expect(context.interface == "call")
    #expect(context.callerProcessID == tab && context.boundProcessID == tab)
    #expect(context.bindsSession == true)
    #expect(context.projectRoot == "/Users/someone/app")
    #expect(context.workingDirectory.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } == directory.resolvingSymlinksInPath().path)
    #expect(context.profile == .unknown)
}

/// A callTool refused with `invalid_request` by an app that still says
/// protocol 2: the refusal is the tool's error, never retried or run here.
@Test func ControlToolPipeACallRefusedByAnAppOfProtocolTwoIsTheToolsError() async throws {
    let app = try PipeTestApp { request, _ in
        switch request {
        case .appInfo: .init(result: .appInfo(pipeAppInfo))
        case .callTool: .init(error: .init(code: "invalid_request", message: "This request is refused."))
        default: .init(error: .init(code: "typed_request", message: "\(request)"))
        }
    }
    defer { app.stop() }
    let session = CherryMCPSession(environment: app.environment)

    let result = await session.call(name: "list_projects", arguments: [:])
    #expect(pipeErrorCode(result) == "invalid_request", "\(result.text)")
    #expect(result.text == #"{"error":{"code":"invalid_request","message":"This request is refused."}}"#)
    let context = await session.callContext(interface: "mcp")
    #expect(app.requests == [.appInfo, .callTool(.init(name: "list_projects", arguments: [:], context: context)), .appInfo])
    #expect(await session.mode == .pipe(pipeAppInfo))
}

/// An app replaced by an older one between `appInfo` and a call: it
/// cannot decode callTool or appInfo, so the call runs here over typed
/// requests, and the session stays legacy.
@Test func ControlToolPipeAnAppReplacedByAnOlderOneRunsTheCallHere() async throws {
    let app = try PipeTestApp { request, before in
        if case .appInfo = request, !before.contains(where: { if case .appInfo = $0 { true } else { false } }) {
            return .init(result: .appInfo(pipeAppInfo))
        }
        if pipeIsToolRequest(request) { return pipeCannotDecode }
        return .init(error: .init(code: "typed_request", message: "A typed request."))
    }
    defer { app.stop() }
    let session = CherryMCPSession(environment: app.environment, workingDirectory: nil)

    let result = await session.call(name: "get_project_status", arguments: [:])
    #expect(pipeErrorCode(result) == "typed_request", "\(result.text)")
    let requests = app.requests
    #expect(Array(requests.prefix(3)).map(pipeIsToolRequest) == [true, true, true])
    // Its environment names no tab: the caller is looked for in the
    // process tree first, as CherryMCP did at startup, then the tool runs.
    #expect(Array(requests.dropFirst(3)) == [.listProcesses(.init()), .getProjectStatus], "\(requests)")
    guard case .legacy = await session.mode else {
        Issue.record("Expected a legacy session, got \(await session.mode)")
        return
    }

    // The next call asks nothing more of the app's version (legacy, as
    // cached) nor of its caller (looked for once).
    _ = await session.call(name: "get_project_status", arguments: [:])
    #expect(Array(app.requests.dropFirst(5)) == [.getProjectStatus])
}

/// Against an app that predates `appInfo`, a name in no list is refused
/// before anything more is sent: the caller is not looked for either.
@Test func ControlToolPipeALegacySessionRefusesAnUnknownToolWithoutSending() async throws {
    let app = try PipeTestApp { request, _ in
        pipeIsToolRequest(request) ? pipeCannotDecode : .init(error: .init(code: "typed_request", message: "A typed request."))
    }
    defer { app.stop() }
    let session = CherryMCPSession(environment: app.environment, workingDirectory: nil)

    let removed = await session.call(name: "create_note", arguments: ["title": .string("Review")])
    #expect(pipeErrorCode(removed) == "unknown_tool", "\(removed.text)")
    #expect(app.requests == [.appInfo])
    guard case .legacy = await session.mode else {
        Issue.record("Expected a legacy session, got \(await session.mode)")
        return
    }
}

/// An app that does not answer `appInfo` with its version (here it refuses
/// the caller): each call is answered as CherryMCP answered before the app
/// ran the tools. A tool in no list is unknown_tool and a missing argument
/// missing_argument, sending nothing more; any other tool reports the
/// app's refusal. The session never turns legacy for it.
@Test func ControlToolPipeWithoutAnAnswerCallsAreRefusedAsBefore() async throws {
    let refused = CherryControlError(code: "unauthorized", message: "This tab is closed.")
    let app = try PipeTestApp { _, _ in .init(error: refused) }
    defer { app.stop() }
    let session = CherryMCPSession(environment: app.environment, workingDirectory: nil)

    let removed = await session.call(name: "create_note", arguments: ["title": .string("Review")])
    #expect(pipeErrorCode(removed) == "unknown_tool", "\(removed.text)")
    let missing = await session.call(name: "get_task", arguments: [:])
    #expect(pipeErrorCode(missing) == "missing_argument", "\(missing.text)")
    #expect(app.requests == [.appInfo, .appInfo])

    let listed = await session.call(name: "list_processes", arguments: [:])
    #expect(listed == CherryToolLayer.errorResult(refused))
    #expect(app.requests == [.appInfo, .appInfo, .appInfo], "the layer's own request fails as appInfo did, unsent")
    #expect(await session.mode == .unknown)
}

/// A new digest in a call's answer (an update replaced the app's tools)
/// sends `notifications/tools/list_changed` before the answer, once; a
/// digest the client was served sends none.
@MainActor
@Test func ControlToolPipeANewDigestSendsListChangedOnce() async throws {
    let harness = try ControlServerHarness()
    defer { harness.stop() }
    harness.server.start()
    let stdio = try PipeStdio()
    defer { stdio.close() }
    let session = CherryMCPSession(environment: [CherryControl.socketEnvironmentKey: harness.socketURL.path])
    let server = try await session.serve(on: stdio.serverTransport())
    let listChanged = JSONValue.string(ToolListChangedNotification.name)

    try stdio.send([pipeInitialize(id: 1, client: "claude-code", version: "2.1.299")])
    _ = try await stdio.response(id: 1)
    try stdio.send([pipeInitialized, pipeToolsList(id: 2)])
    _ = try await stdio.response(id: 2)

    try stdio.send([pipeToolsCall(id: 3, name: "list_projects")])
    let same = try await stdio.response(id: 3)
    #expect(!same.before.contains { $0["method"] == listChanged }, "the digest it was served")

    harness.server.toolsDigestOverrideForTesting = "0123456789abcdef"
    try stdio.send([pipeToolsCall(id: 4, name: "list_projects")])
    let changed = try await stdio.response(id: 4)
    #expect(changed.before.filter { $0["method"] == listChanged }.count == 1, "\(changed.before)")
    #expect(changed.response["result"]?.objectValue?["isError"] != .bool(true))

    try stdio.send([pipeToolsCall(id: 5, name: "list_projects")])
    let again = try await stdio.response(id: 5)
    #expect(!again.before.contains { $0["method"] == listChanged }, "once per digest")
    await server.stop()
}

/// Claude Code asks `server/discover` before `initialize`: refused at once
/// (method not found), and the session goes on.
@Test func ControlToolPipeServerDiscoverIsRefusedAtOnce() async throws {
    let directory = try pipePrivateDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let stdio = try PipeStdio()
    defer { stdio.close() }
    let session = CherryMCPSession(environment: [CherryControl.socketEnvironmentKey: directory.appendingPathComponent("none.sock").path])
    let server = try await session.serve(on: stdio.serverTransport())

    try stdio.send([#"{"jsonrpc":"2.0","id":0,"method":"server/discover","params":{}}"#])
    let discover = try await stdio.response(id: 0, seconds: 2)
    #expect(discover.response["error"]?.objectValue?["code"] == .int(-32601))
    try stdio.send([pipeInitialize(id: 1, client: "claude-code", version: "2.1.299")])
    let initialized = try await stdio.response(id: 1)
    #expect(initialized.response["result"]?.objectValue?["serverInfo"] != nil)
    await server.stop()
}

// MARK: - The client's profile, errors and the command line

/// `--client-tool-timeout <seconds>` (Cherry's launch of Codex) declares the
/// client's limit, whatever it is; MCP_TOOL_TIMEOUT (milliseconds) is
/// Claude Code's own.
@Test func ControlToolPipeTheClientsToolTimeoutComesFromItsLaunch() async {
    let codex = ToolClientInfo(name: "codex-mcp-client", version: "0.162.1")
    let declared = CherryMCPSession(environment: [:], arguments: ["--client-tool-timeout", "300"])
    #expect(await declared.profile.toolTimeoutMilliseconds == 300_000)
    await declared.noteClient(codex)
    #expect(await declared.profile == ToolClientProfile(client: codex, toolTimeoutMilliseconds: 300_000))
    #expect(CherryMCPSession.declaredToolTimeoutMilliseconds(in: ["--stdio", "--client-tool-timeout=120"]) == 120_000)
    #expect(CherryMCPSession.declaredToolTimeoutMilliseconds(in: ["--client-tool-timeout", "soon"]) == nil)
    #expect(CherryMCPSession.declaredToolTimeoutMilliseconds(in: ["--client-tool-timeout", "-5"]) == nil)
    #expect(CherryMCPSession.declaredToolTimeoutMilliseconds(in: ["--client-tool-timeout", "1e300"]) == 86_400_000)
    #expect(CherryMCPSession.declaredToolTimeoutMilliseconds(in: ["--client-tool-timeout"]) == nil)
    #expect(CherryMCPSession.declaredToolTimeoutMilliseconds(in: []) == nil)

    let claude = CherryMCPSession(environment: ["MCP_TOOL_TIMEOUT": "300000"])
    #expect(await claude.profile.toolTimeoutMilliseconds == nil, "MCP_TOOL_TIMEOUT is Claude Code's")
    await claude.noteClient(ToolClientInfo(name: "claude-code", version: "2.1.299"))
    #expect(await claude.profile.toolTimeoutMilliseconds == 300_000)
    let other = CherryMCPSession(environment: ["MCP_TOOL_TIMEOUT": "300000"])
    await other.noteClient(codex)
    #expect(await other.profile.toolTimeoutMilliseconds == nil)
}

/// The helper's own error results (`CherryToolLayer.errorResult`) are
/// encoded as the tool layer encodes an error whose request failed so;
/// get_status's additions keep each side's key style.
@Test func ControlToolPipeErrorsAndStatusFieldsAreEncodedAsTheLayersAre() async throws {
    struct Failing: CherryToolTransport {
        let error: CherryControlError
        var socketPath: String? { nil }
        func send(_ request: CherryControlRequest, timeout: TimeInterval?) async throws -> CherryControlResponse { throw error }
    }
    let error = CherryControlError(code: "schema_mismatch", message: "No/such: \"x\"", details: ["$.a is missing"])
    let layer = await CherryToolLayer.call(name: "list_projects", arguments: [:], caller: CherryToolCaller(), transport: Failing(error: error))
    #expect(CherryToolLayer.errorResult(error) == layer)
    #expect(CherryToolLayer.controlError(error) == error)
    #expect(CherryToolLayer.controlError(POSIXError(.EIO)).code == "tool_error")

    let added = CherryMCPSession.adding(
        ["helper_build": .string("dev"), "app_control_protocol": .int(2)],
        to: CallToolResult(text: #"{"socket_path":"\/tmp\/x"}"#, isError: false, structured: .object(["socketPath": .string("/tmp/x")]))
    )
    #expect(added.text == #"{"app_control_protocol":2,"helper_build":"dev","socket_path":"\/tmp\/x"}"#)
    #expect(added.structured == .object(["socketPath": .string("/tmp/x"), "helperBuild": .string("dev"), "appControlProtocol": .int(2)]))
}

@Test func ControlToolPipeVersionNamesTheBuildAndControlProtocol() async throws {
    #expect(CherryMCPTools.versionJSON(build: "20261015120000.abcdef0")
        == #"{"build":"20261015120000.abcdef0","controlProtocol":2,"name":"CherryMCP","version":"20261015120000.abcdef0"}"#)

    let helper = try pipeBuiltCherryMCP()
    let run = try await pipeRun(helper, ["--version"], environment: ["HOME": NSTemporaryDirectory()])
    #expect(run.status == 0)
    #expect(run.output == CherryMCPTools.versionJSON(build: "dev") + "\n", "a helper outside a bundle or an install is dev")
}

/// `--call` without a name, or with arguments that are not a JSON object:
/// exit 2 and the usage, before anything is sent.
@Test func ControlToolPipeCallUsageAndBadArgumentsExitTwo() async throws {
    let helper = try pipeBuiltCherryMCP()
    let directory = try pipePrivateDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let environment = [
        "HOME": directory.path,
        CherryControl.socketEnvironmentKey: directory.appendingPathComponent("none.sock").path,
    ]

    let usage = try await pipeRun(helper, ["--call"], environment: environment)
    #expect(usage.status == 2)
    #expect(usage.errors == "usage: CherryMCP --call NAME [JSON-ARGUMENTS]\n")
    #expect(usage.output.isEmpty)

    let bad = try await pipeRun(helper, ["--call", "report_result", "{not json"], environment: environment)
    #expect(bad.status == 2)
    #expect(bad.errors.hasPrefix("CherryMCP: the arguments are not a JSON object;"), "\(bad.errors)")
    let array = try await pipeRun(helper, ["--call", "report_result", "[1]"], environment: environment)
    #expect(array.status == 2)
}
