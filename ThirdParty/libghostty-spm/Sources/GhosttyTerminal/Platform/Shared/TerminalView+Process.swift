import Foundation

public extension TerminalView {
    /// PID of the PTY's foreground process group, or nil until one exists.
    var foregroundPid: pid_t? {
        surface?.foregroundPid
    }

    /// Name of the PTY's controlling terminal, or nil until one exists.
    var ttyName: String? {
        surface?.ttyName
    }
}
