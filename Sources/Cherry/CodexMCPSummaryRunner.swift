import Darwin
import Foundation

final class CodexMCPSummaryRunner: @unchecked Sendable {
    enum RunnerError: LocalizedError, Equatable {
        case launchFailed
        case timedOut
        case invalidResponse
        case toolError(String)

        var errorDescription: String? {
            switch self {
            case .launchFailed:
                "Could not launch codex mcp-server."
            case .timedOut:
                "Codex MCP summary timed out."
            case .invalidResponse:
                "Codex MCP returned an invalid response."
            case .toolError(let message):
                "Codex MCP failed: \(message)"
            }
        }
    }

    static let shared = CodexMCPSummaryRunner()

    private let queue = DispatchQueue(label: "Cherry.CodexMCPSummaryRunner")
    private var process: Process?
    private var stdinPipe: Pipe?
    private var stdoutPipe: Pipe?
    private var stderrPipe: Pipe?
    private var stdoutBuffer = Data()
    private var nextRequestID = 1
    private var initialized = false

    func run(
        transcript: String,
        workingDirectory: String,
        model: String,
        timeout: TimeInterval = 20
    ) async throws -> AgentSummaryRunner.Result {
        let prompt = summaryPrompt(for: transcript)
        return try await Task.detached(priority: .utility) {
            try self.queue.sync {
                try self.runBlocking(
                    prompt: prompt,
                    workingDirectory: workingDirectory,
                    model: model,
                    timeout: timeout
                )
            }
        }.value
    }

    private func runBlocking(
        prompt: String,
        workingDirectory: String,
        model: String,
        timeout: TimeInterval
    ) throws -> AgentSummaryRunner.Result {
        try ensureServer()
        let id = nextID()
        let summaryModel = model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? AgentSummaryTool.codex.defaultModel
            : model.trimmingCharacters(in: .whitespacesAndNewlines)
        let request: [String: Any] = [
            "jsonrpc": "2.0",
            "id": id,
            "method": "tools/call",
            "params": [
                "name": "codex",
                "arguments": [
                    "prompt": prompt,
                    "approval-policy": "never",
                    "sandbox": "workspace-write",
                    "cwd": summaryRunnerWorkingDirectoryURL(
                        workingDirectory,
                        fallback: FileManager.default.homeDirectoryForCurrentUser
                    ).path,
                    "model": summaryModel,
                    "include-plan-tool": false,
                    "base-instructions": "Return only a single-line JSON object with keys state and summary. Do not use tools unless necessary.",
                    "config": [
                        "model_reasoning_effort": "low"
                    ]
                ] as [String: Any]
            ] as [String: Any]
        ]

        let response = try sendRequest(request, responseID: id, timeout: timeout)
        if let error = response["error"] as? [String: Any] {
            throw RunnerError.toolError((error["message"] as? String) ?? "unknown error")
        }
        guard let result = response["result"] as? [String: Any] else {
            throw RunnerError.invalidResponse
        }

        let rawOutput = codexMCPText(from: result)
        let summary = summaryFromCommandOutput(rawOutput)
        guard !summary.isEmpty else {
            throw AgentSummaryRunner.SummaryError.emptyOutput
        }
        return .init(summary: summary, prompt: prompt)
    }

    private func ensureServer() throws {
        if let process, process.isRunning, initialized {
            return
        }

        stopServer()

        let nextProcess = Process()
        nextProcess.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        nextProcess.arguments = ["codex", "mcp-server"]
        nextProcess.environment = summaryRunnerEnvironment()
        nextProcess.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

        let nextStdin = Pipe()
        let nextStdout = Pipe()
        let nextStderr = Pipe()
        nextProcess.standardInput = nextStdin
        nextProcess.standardOutput = nextStdout
        nextProcess.standardError = nextStderr

        do {
            try nextProcess.run()
        } catch {
            throw RunnerError.launchFailed
        }

        process = nextProcess
        stdinPipe = nextStdin
        stdoutPipe = nextStdout
        stderrPipe = nextStderr
        stdoutBuffer.removeAll(keepingCapacity: true)
        setNonBlocking(nextStdout.fileHandleForReading.fileDescriptor)
        initialized = false

        let id = nextID()
        _ = try sendRequest([
            "jsonrpc": "2.0",
            "id": id,
            "method": "initialize",
            "params": [
                "protocolVersion": "2024-11-05",
                "capabilities": [:],
                "clientInfo": [
                    "name": "Cherry",
                    "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
                ]
            ]
        ], responseID: id, timeout: 10)

        try sendNotification([
            "jsonrpc": "2.0",
            "method": "notifications/initialized",
            "params": [:]
        ])
        initialized = true
    }

    private func sendRequest(
        _ request: [String: Any],
        responseID: Int,
        timeout: TimeInterval
    ) throws -> [String: Any] {
        try writeJSONLine(request)

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try drainStdout()
            while let line = nextStdoutLine() {
                guard let data = line.data(using: .utf8),
                      let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    continue
                }
                if message["id"] as? Int == responseID {
                    return message
                }
            }
            Thread.sleep(forTimeInterval: 0.02)
        }

        stopServer()
        throw RunnerError.timedOut
    }

    private func sendNotification(_ notification: [String: Any]) throws {
        try writeJSONLine(notification)
    }

    private func writeJSONLine(_ value: [String: Any]) throws {
        guard let stdinPipe else { throw RunnerError.launchFailed }
        let data = try JSONSerialization.data(withJSONObject: value)
        stdinPipe.fileHandleForWriting.write(data)
        stdinPipe.fileHandleForWriting.write(Data([0x0A]))
    }

    private func drainStdout() throws {
        guard let stdoutPipe else { throw RunnerError.launchFailed }
        let fd = stdoutPipe.fileHandleForReading.fileDescriptor
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = Darwin.read(fd, &buffer, buffer.count)
            if count > 0 {
                stdoutBuffer.append(contentsOf: buffer.prefix(count))
                continue
            }
            if count == 0 {
                if process?.isRunning == true {
                    return
                }
                throw RunnerError.launchFailed
            }
            if errno == EAGAIN || errno == EWOULDBLOCK {
                return
            }
            if errno == EINTR {
                continue
            }
            throw RunnerError.launchFailed
        }
    }

    private func nextStdoutLine() -> String? {
        guard let newlineIndex = stdoutBuffer.firstIndex(of: 0x0A) else { return nil }
        let lineData = stdoutBuffer.prefix(upTo: newlineIndex)
        stdoutBuffer.removeSubrange(...newlineIndex)
        return String(data: lineData, encoding: .utf8)
    }

    private func nextID() -> Int {
        defer { nextRequestID += 1 }
        return nextRequestID
    }

    private func stopServer() {
        initialized = false
        stdoutBuffer.removeAll(keepingCapacity: true)
        try? stdinPipe?.fileHandleForWriting.close()
        try? stdoutPipe?.fileHandleForReading.close()
        try? stderrPipe?.fileHandleForReading.close()
        if let process, process.isRunning {
            process.terminate()
        }
        process = nil
        stdinPipe = nil
        stdoutPipe = nil
        stderrPipe = nil
    }

    private func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 {
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
        }
    }
}

func codexMCPText(from result: [String: Any]) -> String {
    if let structuredContent = result["structuredContent"] as? [String: Any],
       let content = structuredContent["content"] as? String {
        return content
    }

    if let content = result["content"] as? [[String: Any]] {
        return content.compactMap { item in
            guard item["type"] as? String == "text" else { return nil }
            return item["text"] as? String
        }.joined(separator: "\n")
    }

    return ""
}
