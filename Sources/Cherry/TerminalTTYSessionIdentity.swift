import Darwin
import Foundation

/// Resolves stable process identity from a PTY name exposed by libghostty.
struct TerminalTTYSessionIdentity: Equatable, Sendable {
    let sessionLeaderPID: pid_t

    init?(ttyName: String) {
        guard let sessionLeaderPID = TerminalTTYDevice.withDescriptor(ttyName, { tcgetsid($0) }),
              sessionLeaderPID > 1
        else { return nil }
        self.sessionLeaderPID = sessionLeaderPID
    }
}

/// The window size a PTY reports to its program (`TIOCGWINSZ`): its grid,
/// and its pixels when its terminal gives them (Ghostty does: its text
/// area's, without the padding).
struct TerminalTTYWindowSize: Equatable, Sendable {
    let columns: Int
    let rows: Int
    let widthPixels: Int
    let heightPixels: Int

    init(columns: Int, rows: Int, widthPixels: Int, heightPixels: Int) {
        self.columns = columns
        self.rows = rows
        self.widthPixels = widthPixels
        self.heightPixels = heightPixels
    }

    init?(ttyName: String) {
        guard let size = TerminalTTYDevice.withDescriptor(ttyName, { descriptor -> winsize? in
            var size = winsize()
            return ioctl(descriptor, TIOCGWINSZ, &size) == 0 ? size : nil
        }) ?? nil, size.ws_col > 0, size.ws_row > 0
        else { return nil }
        self.init(
            columns: Int(size.ws_col),
            rows: Int(size.ws_row),
            widthPixels: Int(size.ws_xpixel),
            heightPixels: Int(size.ws_ypixel)
        )
    }

    /// One cell's pixels as `cherry attach` derives them from the same
    /// report (its pixels over its grid, rounded down; 1 to 1024 each), so
    /// a session created with them (`HostCreateRequest.cell`) gives its
    /// program the pixels this window's adapter will: attaching then
    /// changes nothing. Nil when the PTY reports no pixels.
    var cell: TerminalCellSize? {
        guard columns > 0, rows > 0 else { return nil }
        return TerminalCellSize(width: widthPixels / columns, height: heightPixels / rows)
    }
}

/// The size of one terminal cell in pixels (`cell_width`, `cell_height` of
/// the host protocol): 1 to 1024 each.
struct TerminalCellSize: Equatable, Sendable {
    let width: Int
    let height: Int

    init?(width: Int, height: Int) {
        guard (1...1024).contains(width), (1...1024).contains(height) else { return nil }
        self.width = width
        self.height = height
    }
}

private enum TerminalTTYDevice {
    /// Runs `body` with a descriptor of the terminal libghostty names
    /// (`/dev/ttysNNN`, or its last component), opened without making it
    /// this process's controlling terminal; nil when it cannot be opened.
    static func withDescriptor<Value>(_ ttyName: String, _ body: (Int32) -> Value) -> Value? {
        let trimmedName = ttyName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedName.isEmpty, trimmedName != "not a tty" else { return nil }

        let path = trimmedName.hasPrefix("/dev/")
            ? trimmedName
            : "/dev/\(URL(fileURLWithPath: trimmedName).lastPathComponent)"
        let fileDescriptor = open(path, O_RDONLY | O_NONBLOCK | O_NOCTTY | O_CLOEXEC)
        guard fileDescriptor >= 0 else { return nil }
        defer { close(fileDescriptor) }
        return body(fileDescriptor)
    }
}
