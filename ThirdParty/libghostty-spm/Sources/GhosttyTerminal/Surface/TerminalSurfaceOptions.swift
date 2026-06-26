//
//  TerminalSurfaceOptions.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

import GhosttyKit

public struct TerminalSurfaceOptions: Sendable {
    public var backend: TerminalSessionBackend
    public var fontSize: Float?
    public var workingDirectory: String?
    public var context: TerminalSurfaceContext
    /// For the `.exec` backend: the command ghostty spawns (word-split like a
    /// shell). `nil` => ghostty's default shell.
    public var execCommand: String?
    /// For the `.exec` backend: environment variables for the spawned child.
    public var execEnvironment: [String: String]

    public init(
        backend: TerminalSessionBackend = .exec,
        fontSize: Float? = nil,
        workingDirectory: String? = nil,
        context: TerminalSurfaceContext = .window,
        execCommand: String? = nil,
        execEnvironment: [String: String] = [:]
    ) {
        self.backend = backend
        self.fontSize = fontSize
        self.workingDirectory = workingDirectory
        self.context = context
        self.execCommand = execCommand
        self.execEnvironment = execEnvironment
    }

    func isEquivalent(to other: TerminalSurfaceOptions) -> Bool {
        fontSize == other.fontSize
            && workingDirectory == other.workingDirectory
            && context == other.context
            && execCommand == other.execCommand
            && execEnvironment == other.execEnvironment
            && backend.isEquivalent(to: other.backend)
    }

    var inMemorySession: InMemoryTerminalSession? {
        guard case let .inMemory(session) = backend else { return nil }
        return session
    }

    /// The `.exec` backend spawns and owns a child process, so its surface must be
    /// created even while the view is detached (the process has to run before the
    /// session is ever displayed). In-memory surfaces are pure renderers.
    var isExec: Bool {
        if case .exec = backend { return true }
        return false
    }
}
