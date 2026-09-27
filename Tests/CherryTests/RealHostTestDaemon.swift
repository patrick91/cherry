import Foundation

/// A `cherry-host serve` a real-host test starts on its private socket,
/// which never outlives the test process. The daemon runs under a small
/// shell that holds the other end of a pipe (`lifeline`): when the test
/// process ends in any way (an assertion, a crash, a fatal error, a
/// signal), the shell reads end of file and kills the daemon and every
/// holder of this socket. Otherwise they would keep the test runner's
/// standard error open (holders inherit the daemon's), and `swift test`
/// would wait for them forever.
final class RealHostTestDaemon {
    private let shell: Process
    private let lifeline: Pipe
    /// The daemon's process id.
    let pid: Int32

    /// What the shell does when told (a line) or when the test process ends
    /// (end of file): `stop` ends the daemon with SIGTERM, then its holders;
    /// `crash` kills the daemon alone, as a crash would, and leaves the
    /// holders to the next daemon; anything else (end of file) kills both.
    private static let script = """
        [ -n "$1" ] || exit 1
        "$0" serve --socket "$1" </dev/null >/dev/null &
        daemon=$!
        echo "$daemon"
        read -r how
        case "$how" in
          stop) kill -TERM "$daemon" 2>/dev/null; wait "$daemon" ;;
          crash) kill -KILL "$daemon" 2>/dev/null; wait "$daemon"; exit 0 ;;
          *) kill -KILL "$daemon" 2>/dev/null ;;
        esac
        pkill -KILL -f "hold --socket $1" 2>/dev/null
        exit 0
        """

    /// `environment` must name the private socket (`CHERRY_HOST_SOCKET`) and
    /// `HOME`; `socket` is that socket's path.
    init(executable: URL, environment: [String: String], socket: URL) throws {
        lifeline = Pipe()
        // Only the shell may hold the lifeline open: a child that inherited
        // its write end would keep it from ever reading end of file.
        _ = fcntl(lifeline.fileHandleForWriting.fileDescriptor, F_SETFD, FD_CLOEXEC)
        let output = Pipe()
        shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", Self.script, executable.path, socket.path]
        shell.environment = environment
        shell.standardInput = lifeline
        shell.standardOutput = output
        shell.standardError = FileHandle.standardError
        try shell.run()
        let line = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
        guard let pid = Int32(line.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            try? lifeline.fileHandleForWriting.close()
            shell.waitUntilExit()
            throw CocoaError(.executableLoad, userInfo: [NSLocalizedDescriptionKey: "cherry-host serve did not start"])
        }
        self.pid = pid
    }

    /// Ends every holder of `socket` (SIGKILL): for a test whose daemon is
    /// gone and could not be started again.
    static func endHolders(of socket: URL) {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", #"[ -n "$0" ] && pkill -KILL -f "hold --socket $0""#, socket.path]
        try? shell.run()
        shell.waitUntilExit()
    }

    /// Ends the daemon (SIGTERM) and every holder of its socket, and waits.
    func stop() {
        tell("stop")
    }

    /// Kills the daemon (SIGKILL) as a crash would; the holders keep their
    /// sessions for the next daemon.
    func crash() {
        tell("crash")
    }

    private func tell(_ how: String) {
        guard shell.isRunning else { return }
        try? lifeline.fileHandleForWriting.write(contentsOf: Data("\(how)\n".utf8))
        try? lifeline.fileHandleForWriting.close()
        shell.waitUntilExit()
    }

    deinit {
        tell("stop")
    }
}
