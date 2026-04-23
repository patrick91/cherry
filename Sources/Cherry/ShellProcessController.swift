import Darwin
import Dispatch
import Foundation

private let shellTransportDebugEnabled = ProcessInfo.processInfo.environment["CHERRY_DEBUG_INPUT"] == "1"

struct TerminalViewportSize: Equatable {
    let columns: Int
    let rows: Int
}

final class ShellProcessController: @unchecked Sendable {
    struct Configuration {
        let shellPath: String
        let workingDirectory: String
        let term: String
        let initialSize: TerminalViewportSize
    }

    static let defaultShellPath: String = {
        if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty {
            return shell
        }

        guard let record = getpwuid(getuid()) else {
            return "/bin/zsh"
        }

        return String(cString: record.pointee.pw_shell)
    }()

    static let defaultShellName = URL(fileURLWithPath: defaultShellPath).lastPathComponent

    private let configuration: Configuration
    private let onData: (Data) -> Void
    private let onExit: (Int32) -> Void
    private let ioQueue = DispatchQueue(label: "Cherry.ShellProcess", qos: .userInitiated)

    private var masterFD: Int32 = -1
    private var childPID: pid_t = 0
    private var readSource: DispatchSourceRead?
    private var writeSource: DispatchSourceWrite?
    private var processSource: DispatchSourceProcess?
    private var pendingWrite = Data()
    private var exitReported = false
    private var isTerminating = false
    private var retainedUntilExit: ShellProcessController?

    init(
        configuration: Configuration,
        onData: @escaping (Data) -> Void,
        onExit: @escaping (Int32) -> Void
    ) throws {
        self.configuration = configuration
        self.onData = onData
        self.onExit = onExit

        try launch()
    }

    deinit {
        if childPID > 0, !exitReported {
            _ = kill(childPID, SIGHUP)
            var status: Int32 = 0
            _ = waitpid(childPID, &status, WNOHANG)
        }

        writeSource?.cancel()
        readSource?.cancel()
        processSource?.cancel()
    }

    func write(_ text: String) {
        write(Data(text.utf8))
    }

    func write(_ data: Data) {
        ioQueue.async { [self] in
            guard self.masterFD >= 0 else {
                if shellTransportDebugEnabled {
                    fputs("[pty write skipped] closed fd child=\(self.childPID)\n", stderr)
                }
                return
            }
            guard !data.isEmpty else {
                if shellTransportDebugEnabled {
                    fputs("[pty write skipped] empty payload\n", stderr)
                }
                return
            }

            self.pendingWrite.append(data)
            self.flushPendingWrites()
        }
    }

    func resize(columns: Int, rows: Int) {
        ioQueue.async { [weak self] in
            guard let self, self.masterFD >= 0 else { return }

            var size = winsize(
                ws_row: UInt16(rows),
                ws_col: UInt16(columns),
                ws_xpixel: 0,
                ws_ypixel: 0
            )

            _ = ioctl(self.masterFD, TIOCSWINSZ, &size)
        }
    }

    func terminate() {
        ioQueue.async { [self] in
            self.terminateOnQueue()
        }
    }

    private func launch() throws {
        var master: Int32 = -1
        var size = winsize(
            ws_row: UInt16(configuration.initialSize.rows),
            ws_col: UInt16(configuration.initialSize.columns),
            ws_xpixel: 0,
            ws_ypixel: 0
        )

        let shellPath = configuration.shellPath
        let shellName = URL(fileURLWithPath: shellPath).lastPathComponent
        let workingDirectory = configuration.workingDirectory
        let term = configuration.term

        let pid = forkpty(&master, nil, nil, &size)
        if pid < 0 {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }

        if pid == 0 {
            _ = chdir(workingDirectory)
            _ = setenv("TERM", term, 1)
            _ = setenv("TERM_PROGRAM", "Cherry", 1)
            _ = setenv("COLORTERM", "truecolor", 1)
            _ = setenv("INSIDE_CHERRY", "1", 1)

            shellPath.withCString { shellPathPointer in
                shellName.withCString { shellNamePointer in
                    "-l".withCString { loginFlagPointer in
                        var arguments: [UnsafeMutablePointer<CChar>?] = [
                            UnsafeMutablePointer(mutating: shellNamePointer),
                            UnsafeMutablePointer(mutating: loginFlagPointer),
                            nil
                        ]

                        execv(shellPathPointer, &arguments)
                    }
                }
            }

            _exit(127)
        }

        masterFD = master
        childPID = pid

        let currentFlags = fcntl(master, F_GETFL)
        if currentFlags >= 0 {
            _ = fcntl(master, F_SETFL, currentFlags | O_NONBLOCK)
        }

        if shellTransportDebugEnabled {
            fputs("[pty launch] pid=\(pid) fd=\(master)\n", stderr)
        }

        let readSource = DispatchSource.makeReadSource(fileDescriptor: master, queue: ioQueue)
        readSource.setEventHandler { [weak self] in
            self?.drainReadableData()
        }
        readSource.setCancelHandler {
            _ = close(master)
        }
        self.readSource = readSource
        readSource.resume()

        let processSource = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: ioQueue)
        processSource.setEventHandler { [weak self] in
            self?.handleExitEvent()
        }
        self.processSource = processSource
        processSource.resume()
    }

    private func drainReadableData() {
        guard masterFD >= 0 else { return }

        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            let bytesRead = Darwin.read(masterFD, &buffer, buffer.count)
            if bytesRead > 0 {
                if shellTransportDebugEnabled {
                    fputs("[pty read] fd=\(masterFD) bytes=\(bytesRead)\n", stderr)
                }
                onData(Data(buffer.prefix(bytesRead)))
                continue
            }

            if bytesRead == 0 {
                if shellTransportDebugEnabled {
                    fputs("[pty eof] fd=\(masterFD)\n", stderr)
                }
                handleReadSideClosed()
            }

            if bytesRead < 0, errno != EAGAIN, errno != EINTR {
                if shellTransportDebugEnabled {
                    fputs("[pty read error] fd=\(masterFD) errno=\(errno)\n", stderr)
                }
                handleReadSideClosed()
            }

            break
        }
    }

    private func handleExitEvent() {
        guard !exitReported else { return }

        var status: Int32 = 0
        let waitedPID = waitpid(childPID, &status, 0)
        guard waitedPID == childPID else {
            if waitedPID < 0, errno == ECHILD {
                exitReported = true
                cleanup()
            }
            return
        }

        finishAfterProcessExit(status: status)
    }

    private func terminateOnQueue() {
        guard !isTerminating else { return }

        isTerminating = true
        retainedUntilExit = self
        pendingWrite.removeAll(keepingCapacity: true)
        cancelWriteSource()

        if childPID > 0, !exitReported {
            _ = kill(childPID, SIGHUP)
        }

        cancelReadSource()

        switch reapChildIfAvailable() {
        case .exited(let status):
            finishAfterProcessExit(status: status)
        case .unavailable:
            exitReported = true
            cleanup()
        case .stillRunning:
            if processSource == nil {
                cleanup()
            }
        }
    }

    private func handleReadSideClosed() {
        cancelReadSource()

        switch reapChildIfAvailable() {
        case .exited(let status):
            finishAfterProcessExit(status: status)
        case .unavailable:
            exitReported = true
            cleanup()
        case .stillRunning:
            if processSource == nil {
                cleanup()
            }
        }
    }

    private enum ReapResult {
        case exited(Int32)
        case stillRunning
        case unavailable
    }

    private func reapChildIfAvailable() -> ReapResult {
        guard childPID > 0, !exitReported else { return .unavailable }

        var status: Int32 = 0
        let waitedPID = waitpid(childPID, &status, WNOHANG)
        if waitedPID == childPID {
            return .exited(status)
        }

        if waitedPID == 0 {
            return .stillRunning
        }

        return errno == ECHILD ? .unavailable : .stillRunning
    }

    private func finishAfterProcessExit(status: Int32) {
        guard !exitReported else {
            cleanup()
            return
        }

        exitReported = true
        let exitCode = normalizedExitCode(status)
        if shellTransportDebugEnabled {
            fputs("[pty exit] pid=\(childPID) status=\(exitCode)\n", stderr)
        }
        if !isTerminating {
            onExit(exitCode)
        }
        cleanup()
    }

    private func flushPendingWrites() {
        guard masterFD >= 0 else {
            pendingWrite.removeAll(keepingCapacity: true)
            cancelWriteSource()
            return
        }

        while !pendingWrite.isEmpty {
            let written = pendingWrite.withUnsafeBytes { rawBuffer -> Int in
                guard let baseAddress = rawBuffer.baseAddress else { return 0 }
                return Darwin.write(masterFD, baseAddress, rawBuffer.count)
            }

            if written > 0 {
                if shellTransportDebugEnabled {
                    let chunk = pendingWrite.prefix(written)
                    let rendered = chunk.map { String(format: "%02x", $0) }.joined(separator: " ")
                    fputs("[pty write] fd=\(masterFD) bytes=\(written) data=\(rendered)\n", stderr)
                }
                pendingWrite.removeSubrange(0..<written)
                continue
            }

            if written == 0 {
                ensureWriteSource()
                return
            }

            let writeError = errno
            if writeError == EINTR {
                continue
            }

            if writeError == EAGAIN || writeError == EWOULDBLOCK {
                ensureWriteSource()
                return
            }

            if shellTransportDebugEnabled {
                fputs("[pty write error] fd=\(masterFD) errno=\(writeError)\n", stderr)
            }
            pendingWrite.removeAll(keepingCapacity: true)
            cancelWriteSource()
            return
        }

        cancelWriteSource()
    }

    private func ensureWriteSource() {
        guard writeSource == nil, masterFD >= 0 else { return }

        let writeSource = DispatchSource.makeWriteSource(fileDescriptor: masterFD, queue: ioQueue)
        writeSource.setEventHandler { [weak self] in
            self?.flushPendingWrites()
        }
        self.writeSource = writeSource
        writeSource.resume()
    }

    private func cancelWriteSource() {
        writeSource?.cancel()
        writeSource = nil
    }

    private func cancelReadSource() {
        readSource?.cancel()
        readSource = nil
        masterFD = -1
    }

    private func cleanup() {
        if shellTransportDebugEnabled {
            fputs("[pty cleanup] pid=\(childPID) fd=\(masterFD)\n", stderr)
        }
        pendingWrite.removeAll(keepingCapacity: true)
        cancelWriteSource()
        cancelReadSource()
        processSource?.cancel()
        processSource = nil
        retainedUntilExit = nil
    }

    private func normalizedExitCode(_ status: Int32) -> Int32 {
        let signal = status & 0x7F
        if signal == 0 {
            return (status >> 8) & 0xFF
        }

        return 128 + signal
    }
}
