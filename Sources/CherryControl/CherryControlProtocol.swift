import Foundation

public enum CherryControl {
    public static var socketURL: URL {
        let uid = getuid()
        return URL(fileURLWithPath: "/tmp/cherry-\(uid)/control.sock")
    }

    public static var socketDirectoryURL: URL {
        socketURL.deletingLastPathComponent()
    }
}

public enum CherryControlRequest: Codable, Equatable {
    case listTerminals
    case createTerminal(CreateTerminalRequest)
    case selectTerminal(TerminalIDRequest)
    case sendInput(SendInputRequest)
    case getTerminalOutput(GetTerminalOutputRequest)
    case getTerminalRawOutput(GetTerminalRawOutputRequest)
    case searchOutput(SearchOutputRequest)
    case clearOutput(TerminalIDRequest)
    case restartTerminal(TerminalIDRequest)
    case closeTerminal(TerminalIDRequest)
}

public struct TerminalIDRequest: Codable, Equatable {
    public let terminalID: String

    public init(terminalID: String) {
        self.terminalID = terminalID
    }
}

public struct CreateTerminalRequest: Codable, Equatable {
    public let title: String?
    public let workingDirectory: String?
    public let command: String?

    public init(title: String?, workingDirectory: String?, command: String?) {
        self.title = title
        self.workingDirectory = workingDirectory
        self.command = command
    }
}

public struct SendInputRequest: Codable, Equatable {
    public let terminalID: String
    public let text: String?
    public let rawBase64: String?
    public let waitMilliseconds: Int?
    public let lineLimit: Int?

    public init(
        terminalID: String,
        text: String?,
        rawBase64: String?,
        waitMilliseconds: Int?,
        lineLimit: Int?
    ) {
        self.terminalID = terminalID
        self.text = text
        self.rawBase64 = rawBase64
        self.waitMilliseconds = waitMilliseconds
        self.lineLimit = lineLimit
    }
}

public struct GetTerminalOutputRequest: Codable, Equatable {
    public let terminalID: String
    public let startLine: Int?
    public let lineLimit: Int?

    public init(terminalID: String, startLine: Int?, lineLimit: Int?) {
        self.terminalID = terminalID
        self.startLine = startLine
        self.lineLimit = lineLimit
    }
}

public struct GetTerminalRawOutputRequest: Codable, Equatable {
    public let terminalID: String
    public let maxBytes: Int?

    public init(terminalID: String, maxBytes: Int?) {
        self.terminalID = terminalID
        self.maxBytes = maxBytes
    }
}

public struct SearchOutputRequest: Codable, Equatable {
    public let terminalID: String
    public let query: String
    public let caseSensitive: Bool?
    public let maxMatches: Int?

    public init(terminalID: String, query: String, caseSensitive: Bool?, maxMatches: Int?) {
        self.terminalID = terminalID
        self.query = query
        self.caseSensitive = caseSensitive
        self.maxMatches = maxMatches
    }
}

public struct CherryControlResponse: Codable, Equatable {
    public let result: CherryControlResult?
    public let error: CherryControlError?

    public init(result: CherryControlResult) {
        self.result = result
        self.error = nil
    }

    public init(error: CherryControlError) {
        self.result = nil
        self.error = error
    }
}

public enum CherryControlResult: Codable, Equatable {
    case listTerminals(ListTerminalsResult)
    case createTerminal(TerminalSummaryResult)
    case selectTerminal(SelectTerminalResult)
    case sendInput(SendInputResult)
    case getTerminalOutput(TerminalOutputResult)
    case getTerminalRawOutput(TerminalRawOutputResult)
    case searchOutput(SearchOutputResult)
    case clearOutput(ClearOutputResult)
    case restartTerminal(TerminalSummaryResult)
    case closeTerminal(CloseTerminalResult)
}

public struct CherryControlError: Codable, Equatable, Error {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }
}

public struct TerminalInfo: Codable, Equatable {
    public let id: String
    public let title: String
    public let state: String
    public let selected: Bool
    public let workingDirectory: String
    public let lineCount: Int

    public init(
        id: String,
        title: String,
        state: String,
        selected: Bool,
        workingDirectory: String,
        lineCount: Int
    ) {
        self.id = id
        self.title = title
        self.state = state
        self.selected = selected
        self.workingDirectory = workingDirectory
        self.lineCount = lineCount
    }
}

public struct ListTerminalsResult: Codable, Equatable {
    public let terminals: [TerminalInfo]
    public let selectedTerminalID: String?

    public init(terminals: [TerminalInfo], selectedTerminalID: String?) {
        self.terminals = terminals
        self.selectedTerminalID = selectedTerminalID
    }
}

public struct TerminalSummaryResult: Codable, Equatable {
    public let terminalID: String
    public let title: String
    public let state: String

    public init(terminalID: String, title: String, state: String) {
        self.terminalID = terminalID
        self.title = title
        self.state = state
    }
}

public struct SelectTerminalResult: Codable, Equatable {
    public let terminalID: String
    public let selected: Bool

    public init(terminalID: String, selected: Bool) {
        self.terminalID = terminalID
        self.selected = selected
    }
}

public struct SendInputResult: Codable, Equatable {
    public let terminalID: String
    public let sentBytes: Int
    public let output: TerminalOutputResult?

    public init(terminalID: String, sentBytes: Int, output: TerminalOutputResult?) {
        self.terminalID = terminalID
        self.sentBytes = sentBytes
        self.output = output
    }
}

public struct TerminalOutputResult: Codable, Equatable {
    public let terminalID: String
    public let startLine: Int
    public let endLineExclusive: Int
    public let totalLines: Int
    public let lines: [String]

    public init(
        terminalID: String,
        startLine: Int,
        endLineExclusive: Int,
        totalLines: Int,
        lines: [String]
    ) {
        self.terminalID = terminalID
        self.startLine = startLine
        self.endLineExclusive = endLineExclusive
        self.totalLines = totalLines
        self.lines = lines
    }
}

public struct TerminalRawOutputResult: Codable, Equatable {
    public let terminalID: String
    public let text: String
    public let byteCount: Int
    public let truncated: Bool

    public init(terminalID: String, text: String, byteCount: Int, truncated: Bool) {
        self.terminalID = terminalID
        self.text = text
        self.byteCount = byteCount
        self.truncated = truncated
    }
}

public struct SearchOutputResult: Codable, Equatable {
    public let terminalID: String
    public let matches: [SearchOutputMatch]

    public init(terminalID: String, matches: [SearchOutputMatch]) {
        self.terminalID = terminalID
        self.matches = matches
    }
}

public struct SearchOutputMatch: Codable, Equatable {
    public let lineNumber: Int
    public let text: String

    public init(lineNumber: Int, text: String) {
        self.lineNumber = lineNumber
        self.text = text
    }
}

public struct ClearOutputResult: Codable, Equatable {
    public let terminalID: String
    public let cleared: Bool

    public init(terminalID: String, cleared: Bool) {
        self.terminalID = terminalID
        self.cleared = cleared
    }
}

public struct CloseTerminalResult: Codable, Equatable {
    public let terminalID: String
    public let closed: Bool

    public init(terminalID: String, closed: Bool) {
        self.terminalID = terminalID
        self.closed = closed
    }
}
