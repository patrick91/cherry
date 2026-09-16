import Foundation

public extension TerminalView {
    /// Uses Ghostty's shell-integration state to distinguish an idle prompt
    /// from a running command, including when EXEC uses a login wrapper.
    var needsConfirmQuit: Bool {
        surface?.needsConfirmQuit ?? false
    }

    /// PID of the PTY's foreground process group, or nil until one exists.
    var foregroundPid: pid_t? {
        surface?.foregroundPid
    }

    /// Name of the PTY's controlling terminal, or nil until one exists.
    var ttyName: String? {
        surface?.ttyName
    }
}
