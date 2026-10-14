import Darwin
import Foundation

/// Runs a short command to its end and keeps what it printed: both pipes
/// are read to their end on threads of their own while it runs
/// (`RemoteDeviceShell.readToEnd`), so neither fills, and the caller's
/// thread only waits. Blocking: call it off the main actor, from a thread
/// of its own for a command that can take long (`RemoteDeviceShell.onOwnThread`).
enum CapturedProcess {
    struct Result: Sendable {
        /// The raw `terminationStatus`: the exit code, or the signal for
        /// one that did not exit normally (a timeout's included).
        var status: Int32
        /// Whether it exited rather than being ended by a signal.
        var exitedNormally: Bool
        var standardOutput: Data
        var standardError: Data
        /// It outlived `timeout` and was stopped.
        var timedOut = false
        /// Why it could not be started (then nothing else is set).
        var launchError: (any Error)?
    }

    /// Runs `executable`. A nil `environment` inherits the app's; a nil
    /// `input` gives it /dev/null, else `input` is its whole standard input;
    /// without `captureOutput` its standard output is /dev/null. A nil
    /// `timeout` waits for as long as it runs; else, once it passed, the
    /// command is terminated, then killed 2 s later.
    static func run(
        executable: URL,
        arguments: [String],
        environment: [String: String]?,
        input: Data?,
        captureOutput: Bool = true,
        currentDirectory: URL? = nil,
        timeout: TimeInterval?
    ) -> Result {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }
        let stdin: Pipe? = input == nil ? nil : Pipe()
        let stdout: Pipe? = captureOutput ? Pipe() : nil
        let stderr = Pipe()
        if let stdin { process.standardInput = stdin } else { process.standardInput = FileHandle.nullDevice }
        if let stdout { process.standardOutput = stdout } else { process.standardOutput = FileHandle.nullDevice }
        process.standardError = stderr
        do {
            try process.run()
        } catch {
            return Result(status: -1, exitedNormally: false, standardOutput: Data(), standardError: Data(), launchError: error)
        }
        let group = DispatchGroup()
        let outData = PipeOutputBox()
        let errData = PipeOutputBox()
        if let stdout { RemoteDeviceShell.readToEnd(stdout.fileHandleForReading, into: outData, group: group) }
        RemoteDeviceShell.readToEnd(stderr.fileHandleForReading, into: errData, group: group)
        if let stdin, let input {
            stdin.fileHandleForWriting.write(input)
            try? stdin.fileHandleForWriting.close()
        }
        var timedOut = false
        if let timeout {
            if group.wait(timeout: .now() + timeout) == .timedOut {
                timedOut = true
                process.terminate()
                if group.wait(timeout: .now() + 2) == .timedOut {
                    kill(process.processIdentifier, SIGKILL)
                    _ = group.wait(timeout: .now() + 2)
                }
            }
        } else {
            group.wait()
        }
        process.waitUntilExit()
        return Result(
            status: process.terminationStatus,
            exitedNormally: process.terminationReason == .exit,
            standardOutput: outData.data,
            standardError: errData.data,
            timedOut: timedOut
        )
    }
}
