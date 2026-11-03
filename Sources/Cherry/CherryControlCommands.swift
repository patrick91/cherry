import CherryControl
import Foundation

// MARK: - `cherry` agent commands (control protocol 3)
//
// The Rust `cherry` sends each agent command line as one `runCommand`
// (`CherryToolProtocol.swift`): the app parses it (`CherryCLI`), runs its
// tool as a `callTool` of the same caller (`handleToolCall`, so identity,
// scoping and errors are the tools'), and answers what the command prints.
// What only the caller's Mac has, its standard input, the files it names
// and, for `cherry skill`, what is at the skill's paths, the answer asks for
// (`needsStandardInput`, `needsFiles`, `needsPaths`), and `cherry` sends the
// command again with it: the parse calls nothing before it has everything,
// so nothing runs twice. `cherry skill setup|remove` then answers the steps
// to take there (`operations`), and, sent again with how they went, what
// it did. The skill's files are always the caller's Mac's, This Mac's or
// another's.

extension CherryControlServer {
    /// Runs `command` as its caller, each of its tool's requests sent
    /// through `dispatch` (the caller's `handle`).
    @MainActor
    func handleCommand(
        _ command: RunCommandRequest,
        dispatch: @escaping @Sendable @MainActor (CherryControlRequest) async throws -> CherryControlResponse
    ) async -> RunCommandResult {
        let caller = CallerFiles(command)
        let input = CherryCLIInput(
            hasPipedInput: command.standardInputIsPiped ?? false,
            read: { caller.standardInput() },
            readFile: { path in caller.contents(path).map { String(decoding: $0, as: UTF8.self) } }
        )
        let invocation = CherryCLI.parse(command.arguments, input: input)
        if let missing = caller.needs {
            return missing
        }

        let claimed = command.context ?? ToolCallContext()
        // A command keeps no binding: each is a process of its own.
        let context = ToolCallContext(
            callerProcessID: claimed.callerProcessID,
            bindsSession: false,
            projectRoot: claimed.projectRoot,
            workingDirectory: claimed.workingDirectory,
            interface: "cli"
        )
        let outcome = await CherryCLIRunner.run(
            invocation,
            isTerminal: command.standardOutputIsTerminal ?? false,
            skillInstaller: { request in
                CherryCLIRunner.installer(
                    for: request, variables: command.environment ?? [:], workingDirectory: context.workingDirectory, files: caller
                )
            }
        ) { name, arguments in
            let result = await self.handleToolCall(CallToolRequest(name: name, arguments: arguments, context: context), dispatch: dispatch)
            guard name == "get_status" else { return result }
            let app = Self.appInfo()
            var builds: [String: JSONValue] = [
                "app_build": .string(app.build),
                "app_control_protocol": .int(app.controlProtocol),
            ]
            builds["cli_build"] = command.cliBuild.map(JSONValue.string)
            return Self.adding(builds, to: result)
        }
        if let missing = caller.needs {
            return missing
        }
        if let steps = caller.pendingOperations {
            return RunCommandResult(operations: steps)
        }
        if let problem = caller.resultsProblem {
            return RunCommandResult(standardError: "unexpected_request: \(problem)\n", exitCode: 1)
        }
        return RunCommandResult(
            standardOutput: outcome.standardOutput,
            standardError: outcome.standardError,
            exitCode: outcome.exitCode
        )
    }

    /// `result` with `fields` (snake_case names) added to its payload: in
    /// its text as named, in its structured content in camelCase, as the
    /// layer encodes both.
    static func adding(_ fields: [String: JSONValue], to result: CallToolResult) -> CallToolResult {
        guard case .object(var text)? = try? JSONValue.parse(Data(result.text.utf8)),
              case .object(var structured)? = result.structured
        else {
            return result
        }
        for (name, value) in fields {
            text[name] = value
            structured[camelCase(name)] = value
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(JSONValue.object(text)) else {
            return result
        }
        return CallToolResult(
            text: String(decoding: data, as: UTF8.self),
            isError: result.isError,
            structured: .object(structured),
            bindProcessID: result.bindProcessID,
            toolsDigest: result.toolsDigest
        )
    }

    private static func camelCase(_ name: String) -> String {
        let words = name.split(separator: "_")
        return words.enumerated().map { $0.offset == 0 ? String($0.element) : $0.element.capitalized }.joined()
    }
}

/// The caller's Mac as one round of a command sees it: what the request
/// carries (standard input, files, paths, how the steps went), and what the
/// command wanted that it did not carry. A path or file not carried reads
/// as nothing there (the answer asks for it, so that read never counts); a
/// step is recorded and taken as done until the request says how it went.
private final class CallerFiles: CherrySkillFiles, @unchecked Sendable {
    private let lock = NSLock()
    private let suppliedInput: String?
    private let files: [String: String?]
    private let paths: [String: RunCommandRequest.PathInfo]
    private let results: [RunCommandRequest.OperationResult]?
    private var wantsInput = false
    private var wantedFiles: [String] = []
    private var wantedPaths: [String] = []
    private var steps: [RunCommandResult.Operation] = []
    private var group = 0

    init(_ command: RunCommandRequest) {
        suppliedInput = command.standardInput
        var files: [String: String?] = [:]
        for file in command.files ?? [] { files[file.path] = file.contents }
        self.files = files
        var paths: [String: RunCommandRequest.PathInfo] = [:]
        for info in command.paths ?? [] { paths[info.path] = info }
        self.paths = paths
        results = command.operationResults
    }

    /// The answer asking for what the round lacked, nil when it had all.
    var needs: RunCommandResult? {
        lock.withLock {
            guard wantsInput || !wantedFiles.isEmpty || !wantedPaths.isEmpty else { return nil }
            return RunCommandResult(
                needsStandardInput: wantsInput ? true : nil,
                needsFiles: wantedFiles.isEmpty ? nil : wantedFiles,
                needsPaths: wantedPaths.isEmpty ? nil : wantedPaths
            )
        }
    }

    /// The steps to take, while the request says nothing of them.
    var pendingOperations: [RunCommandResult.Operation]? {
        lock.withLock { results == nil && !steps.isEmpty ? steps : nil }
    }

    /// Why the request's results do not fit this round's steps.
    var resultsProblem: String? {
        lock.withLock {
            guard let results, results.count != steps.count else { return nil }
            return "\(results.count) results for \(steps.count) steps"
        }
    }

    func standardInput() -> String {
        lock.withLock {
            if let suppliedInput { return suppliedInput }
            wantsInput = true
            return ""
        }
    }

    private func info(_ path: String) -> RunCommandRequest.PathInfo? {
        lock.withLock {
            if let info = paths[path] { return info }
            if !wantedPaths.contains(path) { wantedPaths.append(path) }
            return nil
        }
    }

    func entry(_ path: String) -> CherrySkillEntry {
        info(path)?.entry ?? .none
    }

    func isDirectory(_ path: String) -> Bool {
        info(path)?.target == .directory
    }

    func exists(_ path: String) -> Bool {
        (info(path)?.target ?? .none) != .none
    }

    func isExecutable(_ path: String) -> Bool {
        info(path)?.executable == true
    }

    func contents(_ path: String) -> Data? {
        lock.withLock {
            if let file = files[path] { return file.map { Data($0.utf8) } }
            if !wantedFiles.contains(path) { wantedFiles.append(path) }
            return nil
        }
    }

    func list(_ path: String) -> [String]? {
        info(path)?.entries
    }

    func begin(_ target: CherrySkillTarget) {
        lock.withLock { group += 1 }
    }

    func createDirectory(_ path: String) throws {
        try step(.createDirectory, path)
    }

    func write(_ text: String, to path: String) throws {
        try step(.write, path, contents: text)
    }

    func remove(_ path: String) throws {
        try step(.remove, path)
    }

    /// Records a step; once the request says how the steps went, this one's
    /// error is its error.
    private func step(_ kind: RunCommandResult.Operation.Kind, _ path: String, contents: String? = nil) throws {
        let error: String? = lock.withLock {
            let index = steps.count
            steps.append(.init(group: group, kind: kind, path: path, contents: contents))
            guard let results, index < results.count else { return nil }
            return results[index].error
        }
        if let error { throw CherrySkillProblem(error) }
    }
}
