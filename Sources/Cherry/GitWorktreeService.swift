import CryptoKit
import Foundation

struct GitWorktree: Identifiable, Codable, Equatable, Hashable, Sendable {
    let root: String
    let head: String
    let branch: String?
    let isMain: Bool
    let isBare: Bool
    let isDetached: Bool
    let lockReason: String?
    let pruneReason: String?

    var id: String { root }

    var shortHEAD: String {
        String(head.prefix(7))
    }

    var displayName: String {
        if let branch, !branch.isEmpty {
            return branch
        }
        if !shortHEAD.isEmpty {
            return "@\(shortHEAD)"
        }
        return URL(fileURLWithPath: root, isDirectory: true).lastPathComponent
    }

    var isLocked: Bool {
        lockReason != nil
    }

    var isPrunable: Bool {
        pruneReason != nil
    }
}

struct GitRepositorySnapshot: Equatable, Sendable {
    let primaryRoot: String
    let commonDirectory: String
    let worktrees: [GitWorktree]
}

struct GitBranchReference: Identifiable, Equatable, Hashable, Sendable {
    enum Kind: String, Codable, Equatable, Sendable {
        case local
        case remote
    }

    let fullName: String
    let displayName: String
    let objectID: String
    let upstream: String?
    let kind: Kind

    var id: String { fullName }
}

enum GitWorktreeCreation: Equatable, Sendable {
    case newBranch(name: String, startPoint: String, destination: String)
    case localBranch(name: String, destination: String)
    case remoteBranch(remoteName: String, localName: String, destination: String)

    var destination: String {
        switch self {
        case .newBranch(_, _, let destination),
             .localBranch(_, let destination),
             .remoteBranch(_, _, let destination):
            destination
        }
    }
}

struct GitWorktreeCommandError: LocalizedError, Equatable, Sendable {
    let arguments: [String]
    let exitCode: Int32
    let standardError: String

    var errorDescription: String? {
        let message = standardError.trimmingCharacters(in: .whitespacesAndNewlines)
        return message.isEmpty
            ? "Git exited with status \(exitCode)."
            : message
    }
}

struct GitWorktreeService: Sendable {
    func discover(projectRoot: String) async throws -> GitRepositorySnapshot {
        try await Self.perform {
            let records = try Self.runGit(
                ["-C", projectRoot, "worktree", "list", "--porcelain", "-z"]
            )
            let parsed = Self.parseWorktreeList(records.standardOutput)
            guard let first = parsed.first else {
                throw GitWorktreeCommandError(
                    arguments: ["worktree", "list", "--porcelain", "-z"],
                    exitCode: 1,
                    standardError: "Git did not report any worktrees."
                )
            }

            let commonDirectoryResult = try Self.runGit([
                "-C", projectRoot, "rev-parse", "--path-format=absolute", "--git-common-dir"
            ])
            let commonDirectory = Self.decoded(commonDirectoryResult.standardOutput)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let primaryRoot = first.root
            let worktrees = parsed.enumerated().map { index, worktree in
                GitWorktree(
                    root: worktree.root,
                    head: worktree.head,
                    branch: worktree.branch,
                    isMain: index == 0,
                    isBare: worktree.isBare,
                    isDetached: worktree.isDetached,
                    lockReason: worktree.lockReason,
                    pruneReason: worktree.pruneReason
                )
            }
            return GitRepositorySnapshot(
                primaryRoot: primaryRoot,
                commonDirectory: commonDirectory,
                worktrees: worktrees
            )
        }
    }

    func branchReferences(repositoryRoot: String) async throws -> [GitBranchReference] {
        try await Self.perform {
            let result = try Self.runGit([
                "-C", repositoryRoot,
                "for-each-ref",
                "--format=%(refname)%00%(objectname)%00%(upstream:short)",
                "refs/heads", "refs/remotes"
            ])
            return Self.parseBranchReferences(result.standardOutput)
        }
    }

    func validateBranchName(_ branchName: String, repositoryRoot: String) async throws {
        _ = try await Self.perform {
            try Self.runGit([
                "-C", repositoryRoot, "check-ref-format", "--branch", branchName
            ])
        }
    }

    func isDirty(worktreeRoot: String) async throws -> Bool {
        try await Self.perform {
            try Self.dirtyStatus(worktreeRoot: worktreeRoot)
        }
    }

    func dirtyStatuses(worktreeRoots: [String]) async -> [String: Bool] {
        do {
            return try await Self.perform {
                var statuses: [String: Bool] = [:]
                for root in worktreeRoots {
                    do {
                        statuses[root] = try Self.dirtyStatus(worktreeRoot: root)
                    } catch {
                        // A worktree can disappear between discovery and this check.
                    }
                }
                return statuses
            }
        } catch {
            return [:]
        }
    }

    func create(_ creation: GitWorktreeCreation, repositoryRoot: String) async throws {
        try await Self.perform {
            let destination = URL(
                fileURLWithPath: creation.destination,
                isDirectory: true
            ).standardizedFileURL.path
            try FileManager.default.createDirectory(
                at: URL(fileURLWithPath: destination, isDirectory: true).deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let arguments: [String]
            switch creation {
            case .newBranch(let name, let startPoint, _):
                arguments = [
                    "-C", repositoryRoot, "worktree", "add", "-b", name,
                    destination, startPoint
                ]
            case .localBranch(let name, _):
                arguments = [
                    "-C", repositoryRoot, "worktree", "add", destination, name
                ]
            case .remoteBranch(let remoteName, let localName, _):
                arguments = [
                    "-C", repositoryRoot, "worktree", "add", "--track", "-b",
                    localName, destination, remoteName
                ]
            }
            _ = try Self.runGit(arguments)
        }
    }

    func renameBranch(worktreeRoot: String, newName: String) async throws {
        try await Self.perform {
            _ = try Self.runGit([
                "-C", worktreeRoot, "branch", "-m", newName
            ])
        }
    }

    func remove(
        worktreeRoot: String,
        repositoryRoot: String,
        force: Bool = false
    ) async throws {
        try await Self.perform {
            var arguments = ["-C", repositoryRoot, "worktree", "remove"]
            if force {
                // Git requires force twice when a worktree is locked. The same
                // form also covers modified/untracked files.
                arguments.append(contentsOf: ["--force", "--force"])
            }
            arguments.append(worktreeRoot)
            _ = try Self.runGit(arguments)
        }
    }

    func prune(repositoryRoot: String) async throws {
        try await Self.perform {
            _ = try Self.runGit(["-C", repositoryRoot, "worktree", "prune"])
        }
    }

    func fetch(repositoryRoot: String) async throws {
        try await Self.perform {
            _ = try Self.runGit(["-C", repositoryRoot, "fetch", "--prune"])
        }
    }

    static func managedWorktreeRoot(
        repositoryName: String,
        repositoryIdentity: String,
        branchName: String,
        fileManager: FileManager = .default
    ) -> String {
        let repositorySlug = slug(repositoryName, fallback: "repository")
        let branchSlug = slug(branchName.replacingOccurrences(of: "/", with: "-"), fallback: "worktree")
        let digest = SHA256.hash(data: Data(repositoryIdentity.utf8))
        let identity = digest.prefix(4).map { String(format: "%02x", $0) }.joined()
        let parent = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent(".cherry", isDirectory: true)
            .appendingPathComponent("worktrees", isDirectory: true)
            .appendingPathComponent("\(repositorySlug)-\(identity)", isDirectory: true)

        var candidate = parent.appendingPathComponent(branchSlug, isDirectory: true)
        var suffix = 2
        while fileManager.fileExists(atPath: candidate.path) {
            candidate = parent.appendingPathComponent("\(branchSlug)-\(suffix)", isDirectory: true)
            suffix += 1
        }
        return candidate.path
    }

    static func parseWorktreeList(_ data: Data) -> [GitWorktree] {
        let fields = data.split(separator: 0, omittingEmptySubsequences: false)
        var records: [GitWorktree] = []
        var current: PartialWorktree?

        func finishCurrent() {
            guard let value = current, !value.root.isEmpty else {
                current = nil
                return
            }
            records.append(GitWorktree(
                root: value.root,
                head: value.head,
                branch: value.branch,
                isMain: records.isEmpty,
                isBare: value.isBare,
                isDetached: value.isDetached,
                lockReason: value.lockReason,
                pruneReason: value.pruneReason
            ))
            current = nil
        }

        for fieldData in fields {
            guard !fieldData.isEmpty else {
                finishCurrent()
                continue
            }
            let field = decoded(Data(fieldData))
            let key: String
            let value: String
            if let separator = field.firstIndex(of: " ") {
                key = String(field[..<separator])
                value = String(field[field.index(after: separator)...])
            } else {
                key = field
                value = ""
            }

            if key == "worktree" {
                finishCurrent()
                current = PartialWorktree(root: value)
                continue
            }
            guard current != nil else { continue }
            switch key {
            case "HEAD": current?.head = value
            case "branch":
                current?.branch = value.hasPrefix("refs/heads/")
                    ? String(value.dropFirst("refs/heads/".count))
                    : value
            case "bare": current?.isBare = true
            case "detached": current?.isDetached = true
            case "locked": current?.lockReason = value.isEmpty ? "Locked" : value
            case "prunable": current?.pruneReason = value.isEmpty ? "Prunable" : value
            default: break
            }
        }
        finishCurrent()
        return records
    }

    static func parseBranchReferences(_ data: Data) -> [GitBranchReference] {
        decoded(data)
            .split(whereSeparator: \.isNewline)
            .compactMap { rawLine in
                let fields = rawLine.split(separator: "\0", omittingEmptySubsequences: false)
                guard fields.count >= 2 else { return nil }
                let fullName = String(fields[0])
                let objectID = String(fields[1])
                let upstream = fields.count > 2 && !fields[2].isEmpty ? String(fields[2]) : nil
                if fullName.hasPrefix("refs/heads/") {
                    return GitBranchReference(
                        fullName: fullName,
                        displayName: String(fullName.dropFirst("refs/heads/".count)),
                        objectID: objectID,
                        upstream: upstream,
                        kind: .local
                    )
                }
                if fullName.hasPrefix("refs/remotes/") {
                    let displayName = String(fullName.dropFirst("refs/remotes/".count))
                    guard !displayName.hasSuffix("/HEAD") else { return nil }
                    return GitBranchReference(
                        fullName: fullName,
                        displayName: displayName,
                        objectID: objectID,
                        upstream: upstream,
                        kind: .remote
                    )
                }
                return nil
            }
            .sorted { lhs, rhs in
                if lhs.kind != rhs.kind {
                    return lhs.kind == .local
                }
                return lhs.displayName.localizedStandardCompare(rhs.displayName) == .orderedAscending
            }
    }

    private struct PartialWorktree {
        var root: String
        var head = ""
        var branch: String?
        var isBare = false
        var isDetached = false
        var lockReason: String?
        var pruneReason: String?
    }

    private struct GitResult {
        let standardOutput: Data
        let standardError: Data
        let exitCode: Int32
    }

    private final class PipeCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var captured = Data()

        func readToEnd(from handle: FileHandle) {
            let data = handle.readDataToEndOfFile()
            lock.lock()
            captured = data
            lock.unlock()
        }

        var data: Data {
            lock.lock()
            defer { lock.unlock() }
            return captured
        }
    }

    private static func perform<T: Sendable>(
        _ operation: @escaping @Sendable () throws -> T
    ) async throws -> T {
        try await Task.detached(priority: .userInitiated, operation: operation).value
    }

    private static func runGit(_ arguments: [String]) throws -> GitResult {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.standardOutput = output
        process.standardError = error

        do {
            try process.run()
        } catch {
            throw GitWorktreeCommandError(
                arguments: arguments,
                exitCode: -1,
                standardError: error.localizedDescription
            )
        }

        let outputCapture = PipeCapture()
        let errorCapture = PipeCapture()
        let readGroup = DispatchGroup()
        readGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            outputCapture.readToEnd(from: output.fileHandleForReading)
            readGroup.leave()
        }
        readGroup.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            errorCapture.readToEnd(from: error.fileHandleForReading)
            readGroup.leave()
        }
        process.waitUntilExit()
        readGroup.wait()
        let result = GitResult(
            standardOutput: outputCapture.data,
            standardError: errorCapture.data,
            exitCode: process.terminationStatus
        )
        guard result.exitCode == 0 else {
            throw GitWorktreeCommandError(
                arguments: arguments,
                exitCode: result.exitCode,
                standardError: decoded(result.standardError)
            )
        }
        return result
    }

    private static func dirtyStatus(worktreeRoot: String) throws -> Bool {
        let result = try runGit([
            "-C", worktreeRoot, "status", "--porcelain=v1", "--untracked-files=normal"
        ])
        return !result.standardOutput.isEmpty
    }

    private static func decoded(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    private static func slug(_ value: String, fallback: String) -> String {
        let lowered = value.lowercased()
        var result = ""
        var previousWasDash = false
        for scalar in lowered.unicodeScalars {
            let isAllowed = CharacterSet.alphanumerics.contains(scalar)
            if isAllowed {
                result.unicodeScalars.append(scalar)
                previousWasDash = false
            } else if !previousWasDash, !result.isEmpty {
                result.append("-")
                previousWasDash = true
            }
        }
        result = result.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return result.isEmpty ? fallback : result
    }
}
