import Foundation

private enum SidebarTerminalPathString {
    static func lastPathComponent(_ value: String) -> String {
        guard !value.isEmpty else { return "" }

        var end = value.endIndex
        while end > value.startIndex, value[value.index(before: end)] == "/" {
            end = value.index(before: end)
        }
        guard end > value.startIndex else { return "/" }

        let trimmed = value[..<end]
        guard let separator = trimmed.lastIndex(of: "/") else {
            return String(trimmed)
        }

        let start = value.index(after: separator)
        return String(value[start..<end])
    }
}

enum SidebarTerminalProgramFormatter {
    static func label(
        for title: String,
        workingDirectory: String,
        homeDirectory: String = NSHomeDirectory()
    ) -> SidebarTerminalPathLabel? {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return nil }

        if let appLabel = appTitleLabel(for: trimmedTitle) {
            return appLabel
        }

        let tokens = effectiveCommandTokens(ShellCommandTokenizer.tokens(from: trimmedTitle))
        guard let firstToken = tokens.first else { return nil }

        if let runnerLabel = runnerLabel(for: tokens, rawCommand: trimmedTitle) {
            return runnerLabel
        }

        guard let descriptor = ProgramCatalog.descriptor(forExecutable: firstToken) else {
            return nil
        }

        let detail = trimmedTitle
        let title: String
        if descriptor.prefersArgumentTitle,
           let argumentTitle = argumentTitle(from: Array(tokens.dropFirst()), workingDirectory: workingDirectory, homeDirectory: homeDirectory) {
            title = argumentTitle
        } else if descriptor.prefersSubcommandTitle,
                  let subcommand = firstSubcommand(from: Array(tokens.dropFirst())) {
            title = "\(descriptor.displayName) \(subcommand)"
        } else {
            title = descriptor.displayName
        }

        return label(title: title, detail: detail, descriptor: descriptor)
    }

    private static func appTitleLabel(for title: String) -> SidebarTerminalPathLabel? {
        guard let separator = title.range(of: " - ", options: .backwards) else { return nil }

        let appName = String(title[separator.upperBound...])
        guard let descriptor = ProgramCatalog.descriptor(forExecutable: appName) else { return nil }

        let subject = String(title[..<separator.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !subject.isEmpty else { return nil }

        let parsedSubject = splitTrailingParenthetical(subject)
        let detail = parsedSubject.parenthetical.map { "\($0) · \(descriptor.displayName)" } ?? descriptor.displayName
        return label(title: parsedSubject.title, detail: detail, descriptor: descriptor)
    }

    private static func runnerLabel(for tokens: [String], rawCommand: String) -> SidebarTerminalPathLabel? {
        guard let runnerTarget = runnerTarget(from: tokens) else { return nil }

        let descriptor = ProgramCatalog.descriptor(forPackageOrExecutable: runnerTarget.target)
        let title = descriptor?.displayName ?? displayName(forPackage: runnerTarget.target)
        return label(
            title: title,
            detail: rawCommand,
            descriptor: descriptor ?? runnerTarget.runner
        )
    }

    private static func label(
        title: String,
        detail: String,
        descriptor: ProgramDescriptor
    ) -> SidebarTerminalPathLabel {
        SidebarTerminalPathLabel(
            title: title,
            detail: detail,
            leadingIconResourceName: descriptor.logoResourceName,
            leadingIconFallback: descriptor.fallbackLabel,
            leadingIconRendersAsTemplate: descriptor.logoResourceName != nil && descriptor.rendersAsTemplate
        )
    }

    private static func effectiveCommandTokens(_ tokens: [String]) -> [String] {
        var remaining = tokens

        while let first = remaining.first {
            let name = ProgramCatalog.normalizedExecutableName(first)

            if isAssignment(first) {
                remaining.removeFirst()
                continue
            }

            if name == "env" {
                remaining.removeFirst()
                while let next = remaining.first {
                    if isAssignment(next) {
                        remaining.removeFirst()
                    } else if next.hasPrefix("-") {
                        let option = remaining.removeFirst()
                        if optionTakesValue(option), !remaining.isEmpty {
                            remaining.removeFirst()
                        }
                    } else {
                        break
                    }
                }
                continue
            }

            if name == "sudo" || name == "doas" {
                remaining.removeFirst()
                while let next = remaining.first, next.hasPrefix("-") {
                    let option = remaining.removeFirst()
                    if optionTakesValue(option), !remaining.isEmpty {
                        remaining.removeFirst()
                    }
                }
                continue
            }

            if wrapperCommands.contains(name) {
                remaining.removeFirst()
                continue
            }

            break
        }

        return remaining
    }

    private static func runnerTarget(from tokens: [String]) -> (runner: ProgramDescriptor, target: String)? {
        guard let first = tokens.first else { return nil }
        let executable = ProgramCatalog.normalizedExecutableName(first)

        switch executable {
        case "bunx":
            guard let runner = ProgramCatalog.descriptor(forExecutable: "bunx"),
                  let target = firstRunnableToken(from: Array(tokens.dropFirst()))
            else { return nil }
            return (runner, target)
        case "npx":
            guard let runner = ProgramCatalog.descriptor(forExecutable: "npx"),
                  let target = firstRunnableToken(from: Array(tokens.dropFirst()))
            else { return nil }
            return (runner, target)
        case "uvx":
            guard let runner = ProgramCatalog.descriptor(forExecutable: "uvx"),
                  let target = firstRunnableToken(from: Array(tokens.dropFirst()))
            else { return nil }
            return (runner, target)
        case "uv":
            guard tokens.count >= 2,
                  tokens[1].lowercased() == "run",
                  let runner = ProgramCatalog.descriptor(forExecutable: "uv"),
                  let target = firstRunnableToken(from: Array(tokens.dropFirst(2)))
            else { return nil }
            return (runner, target)
        case "npm", "pnpm", "yarn":
            guard tokens.count >= 2 else { return nil }
            let subcommand = tokens[1].lowercased()
            let runnerSubcommands: Set<String>
            if executable == "npm" {
                runnerSubcommands = ["exec", "x"]
            } else {
                runnerSubcommands = ["dlx", "exec"]
            }
            guard runnerSubcommands.contains(subcommand),
                  let runner = ProgramCatalog.descriptor(forExecutable: executable),
                  let target = firstRunnableToken(from: Array(tokens.dropFirst(2)))
            else { return nil }
            return (runner, target)
        default:
            return nil
        }
    }

    private static func firstRunnableToken(from tokens: [String]) -> String? {
        var index = 0
        while index < tokens.count {
            let token = tokens[index]
            if token == "--" {
                index += 1
                continue
            }
            if isAssignment(token) {
                index += 1
                continue
            }
            if token.hasPrefix("-") {
                if optionTakesValue(token), index + 1 < tokens.count {
                    index += 2
                } else {
                    index += 1
                }
                continue
            }
            return token
        }
        return nil
    }

    private static func argumentTitle(
        from tokens: [String],
        workingDirectory: String,
        homeDirectory: String
    ) -> String? {
        for token in tokens {
            guard token != "--" else { continue }
            guard !token.hasPrefix("-"), !token.hasPrefix("+"), !isAssignment(token) else { continue }

            if token == "." {
                return SidebarTerminalPathString.lastPathComponent(workingDirectory).nilIfEmpty
            }

            let expanded = token.hasPrefix("~/")
                ? homeDirectory + "/" + token.dropFirst(2)
                : token
            let lastComponent = SidebarTerminalPathString.lastPathComponent(String(expanded))
            return lastComponent.nilIfEmpty ?? token
        }
        return nil
    }

    private static func firstSubcommand(from tokens: [String]) -> String? {
        for token in tokens {
            guard token != "--" else { continue }
            guard !token.hasPrefix("-"), !isAssignment(token) else { continue }
            return token
        }
        return nil
    }

    private static func displayName(forPackage token: String) -> String {
        cleanedPackageName(token)
    }

    private static func cleanedPackageName(_ token: String) -> String {
        var package = SidebarTerminalPathString.lastPathComponent(token)
        if package.hasPrefix("@"), let slash = package.firstIndex(of: "/") {
            package = String(package[package.index(after: slash)...])
        }
        if let version = package.dropFirst().lastIndex(of: "@") {
            package = String(package[..<version])
        }
        return package.nilIfEmpty ?? token
    }

    private static func splitTrailingParenthetical(_ value: String) -> (title: String, parenthetical: String?) {
        guard value.hasSuffix(")"),
              let open = value.lastIndex(of: "(")
        else {
            return (value, nil)
        }

        let title = value[..<open].trimmingCharacters(in: .whitespacesAndNewlines)
        let parentheticalStart = value.index(after: open)
        let parentheticalEnd = value.index(before: value.endIndex)
        let parenthetical = value[parentheticalStart..<parentheticalEnd]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !parenthetical.isEmpty else {
            return (value, nil)
        }
        return (title, parenthetical)
    }

    private static func isAssignment(_ token: String) -> Bool {
        guard let equals = token.firstIndex(of: "="), equals != token.startIndex else { return false }
        let name = token[..<equals]
        guard let first = name.first, first == "_" || first.isLetter else { return false }
        return name.allSatisfy { $0 == "_" || $0.isLetter || $0.isNumber }
    }

    private static func optionTakesValue(_ option: String) -> Bool {
        guard !option.contains("=") else { return false }
        return optionsTakingValue.contains(option)
    }

    private static let wrapperCommands: Set<String> = [
        "arch", "command", "exec", "noglob", "time"
    ]

    private static let optionsTakingValue: Set<String> = [
        "-C", "-E", "-H", "-P", "-S", "-c", "-g", "-h", "-p", "-u",
        "--cache", "--cwd", "--directory", "--package", "--prefix", "--registry",
        "--shell", "--user", "--userconfig"
    ]
}

enum SidebarProjectCommandFormatter {
    static func label(
        for command: ProjectCommandDefinition,
        projectRoot: String?,
        homeDirectory: String = NSHomeDirectory()
    ) -> SidebarTerminalPathLabel {
        let title = command.name.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Command"
        let subtitle = subtitle(for: command, projectRoot: projectRoot, homeDirectory: homeDirectory)
        let programLabel = programLabel(for: command, projectRoot: projectRoot, homeDirectory: homeDirectory)

        return SidebarTerminalPathLabel(
            title: title,
            detail: subtitle?.text,
            detailIconResourceName: subtitle?.iconResourceName,
            leadingIconResourceName: programLabel?.leadingIconResourceName,
            leadingIconFallback: programLabel?.leadingIconFallback,
            leadingIconRendersAsTemplate: programLabel?.leadingIconRendersAsTemplate ?? false
        )
    }

    private static func programLabel(
        for command: ProjectCommandDefinition,
        projectRoot: String?,
        homeDirectory: String
    ) -> SidebarTerminalPathLabel? {
        let commandLine = displayCommandLine(for: command)
        guard !commandLine.isEmpty else { return nil }

        let workingDirectory = projectRoot.map {
            command.resolvedWorkingDirectory(projectRoot: $0)
        } ?? homeDirectory
        return SidebarTerminalProgramFormatter.label(
            for: commandLine,
            workingDirectory: workingDirectory,
            homeDirectory: homeDirectory
        )
    }

    private static func subtitle(
        for command: ProjectCommandDefinition,
        projectRoot: String?,
        homeDirectory: String
    ) -> SidebarProjectCommandSubtitle? {
        let hasArguments = !command.arguments.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !hasArguments,
           command.environment.isEmpty,
           let projectRoot,
           let repoPath = SidebarTerminalPathFormatter.githubRepositoryPath(
               for: command.resolvedWorkingDirectory(projectRoot: projectRoot),
               homeDirectory: homeDirectory
           ) {
            return SidebarProjectCommandSubtitle(text: repoPath, iconResourceName: "github")
        }

        return displayCommandLine(for: command)
            .nilIfEmpty
            .map { SidebarProjectCommandSubtitle(text: $0, iconResourceName: nil) }
    }

    private static func displayCommandLine(for command: ProjectCommandDefinition) -> String {
        let commandLine = command.commandLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !commandLine.isEmpty else { return "" }

        let environmentPrefix = command.environment.keys
            .filter(ProjectCommandEnvironmentExtraction.isValidEnvironmentName)
            .sorted()
            .map { "\($0)=..." }
            .joined(separator: " ")
        guard !environmentPrefix.isEmpty else { return commandLine }
        return "\(environmentPrefix) \(commandLine)"
    }
}

private struct SidebarProjectCommandSubtitle {
    let text: String
    let iconResourceName: String?
}

private struct ProgramDescriptor {
    let displayName: String
    let logoResourceName: String?
    let fallbackLabel: String
    let rendersAsTemplate: Bool
    let prefersArgumentTitle: Bool
    let prefersSubcommandTitle: Bool

    init(
        displayName: String,
        logoResourceName: String? = nil,
        fallbackLabel: String,
        rendersAsTemplate: Bool = true,
        prefersArgumentTitle: Bool = false,
        prefersSubcommandTitle: Bool = false
    ) {
        self.displayName = displayName
        self.logoResourceName = logoResourceName
        self.fallbackLabel = fallbackLabel
        self.rendersAsTemplate = rendersAsTemplate
        self.prefersArgumentTitle = prefersArgumentTitle
        self.prefersSubcommandTitle = prefersSubcommandTitle
    }
}

private enum ProgramCatalog {
    static func descriptor(forExecutable executable: String) -> ProgramDescriptor? {
        let normalized = normalizedExecutableName(executable)
        let key = aliases[normalized] ?? normalized
        return descriptors[key]
    }

    static func descriptor(forPackageOrExecutable value: String) -> ProgramDescriptor? {
        descriptor(forExecutable: cleanedPackageOrExecutable(value))
    }

    static func normalizedExecutableName(_ value: String) -> String {
        var name = SidebarTerminalPathString.lastPathComponent(value).lowercased()
        if name.hasSuffix(".exe") {
            name.removeLast(4)
        }
        if isVersionedExecutable(name, prefix: "python") {
            return "python"
        }
        if isVersionedExecutable(name, prefix: "node") {
            return "node"
        }
        return name
    }

    private static func cleanedPackageOrExecutable(_ value: String) -> String {
        var package = SidebarTerminalPathString.lastPathComponent(value)
        if package.hasPrefix("@"), let slash = package.firstIndex(of: "/") {
            package = String(package[package.index(after: slash)...])
        }
        if let version = package.dropFirst().lastIndex(of: "@") {
            package = String(package[..<version])
        }
        return package
    }

    private static func isVersionedExecutable(_ name: String, prefix: String) -> Bool {
        guard name.hasPrefix(prefix) else { return false }
        return name.dropFirst(prefix.count).allSatisfy { character in
            character.isNumber || character == "."
        }
    }

    private static let aliases: [String: String] = [
        "vi": "vim",
        "view": "vim",
        "vimdiff": "vim",
        "nvimdiff": "nvim",
        "nodejs": "node",
        "python3": "python",
        "pip": "python",
        "pip3": "python",
        "cargo": "rust",
        "rustc": "rust",
        "ruff": "ruff",
        "ruff-lsp": "ruff",
        "uvicorn": "fastapi",
        "py.test": "pytest",
        "pytest3": "pytest",
        "nextjs": "next",
        "create-vite": "vite",
        "create-next-app": "create-next-app"
    ]

    private static let descriptors: [String: ProgramDescriptor] = [
        "vim": ProgramDescriptor(displayName: "Vim", logoResourceName: "vim", fallbackLabel: "Vi", prefersArgumentTitle: true),
        "nvim": ProgramDescriptor(displayName: "Nvim", logoResourceName: "neovim", fallbackLabel: "Nv", prefersArgumentTitle: true),
        "emacs": ProgramDescriptor(displayName: "Emacs", logoResourceName: "gnuemacs", fallbackLabel: "Em", prefersArgumentTitle: true),
        "nano": ProgramDescriptor(displayName: "Nano", fallbackLabel: "Na", prefersArgumentTitle: true),
        "less": ProgramDescriptor(displayName: "less", fallbackLabel: "Ls", prefersArgumentTitle: true),
        "man": ProgramDescriptor(displayName: "man", fallbackLabel: "Ma", prefersArgumentTitle: true),
        "git": ProgramDescriptor(displayName: "Git", logoResourceName: "git", fallbackLabel: "Gt", prefersSubcommandTitle: true),
        "gh": ProgramDescriptor(displayName: "GitHub", logoResourceName: "github", fallbackLabel: "GH", prefersSubcommandTitle: true),
        "node": ProgramDescriptor(displayName: "Node.js", logoResourceName: "nodedotjs", fallbackLabel: "JS"),
        "npm": ProgramDescriptor(displayName: "npm", logoResourceName: "npm", fallbackLabel: "np"),
        "npx": ProgramDescriptor(displayName: "npx", logoResourceName: "npm", fallbackLabel: "nx"),
        "pnpm": ProgramDescriptor(displayName: "pnpm", logoResourceName: "pnpm", fallbackLabel: "pn"),
        "yarn": ProgramDescriptor(displayName: "Yarn", logoResourceName: "yarn", fallbackLabel: "Ya"),
        "bun": ProgramDescriptor(displayName: "Bun", logoResourceName: "bun", fallbackLabel: "Bn"),
        "bunx": ProgramDescriptor(displayName: "bunx", logoResourceName: "bun", fallbackLabel: "Bx"),
        "uv": ProgramDescriptor(displayName: "uv", logoResourceName: "uv", fallbackLabel: "uv"),
        "uvx": ProgramDescriptor(displayName: "uvx", logoResourceName: "uv", fallbackLabel: "ux"),
        "python": ProgramDescriptor(displayName: "Python", logoResourceName: "python", fallbackLabel: "Py"),
        "deno": ProgramDescriptor(displayName: "Deno", logoResourceName: "deno", fallbackLabel: "De"),
        "docker": ProgramDescriptor(displayName: "Docker", logoResourceName: "docker", fallbackLabel: "Do", prefersSubcommandTitle: true),
        "go": ProgramDescriptor(displayName: "Go", logoResourceName: "go", fallbackLabel: "Go", prefersSubcommandTitle: true),
        "swift": ProgramDescriptor(displayName: "Swift", logoResourceName: "swift", fallbackLabel: "Sw", prefersSubcommandTitle: true),
        "rust": ProgramDescriptor(displayName: "Rust", logoResourceName: "rust", fallbackLabel: "Rs", prefersSubcommandTitle: true),
        "vite": ProgramDescriptor(displayName: "Vite", logoResourceName: "vite", fallbackLabel: "Vt"),
        "fastapi": ProgramDescriptor(displayName: "FastAPI", logoResourceName: "fastapi", fallbackLabel: "Fa"),
        "ruff": ProgramDescriptor(displayName: "Ruff", logoResourceName: "ruff", fallbackLabel: "Rf"),
        "pytest": ProgramDescriptor(displayName: "Pytest", logoResourceName: "pytest", fallbackLabel: "Py"),
        "next": ProgramDescriptor(displayName: "Next.js", logoResourceName: "nextdotjs", fallbackLabel: "Nx"),
        "create-next-app": ProgramDescriptor(displayName: "create-next-app", logoResourceName: "nextdotjs", fallbackLabel: "nx")
    ]
}

private enum ShellCommandTokenizer {
    static func tokens(from command: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?
        var isEscaping = false

        for character in command {
            if isEscaping {
                current.append(character)
                isEscaping = false
                continue
            }

            if character == "\\", quote != "'" {
                isEscaping = true
                continue
            }

            if let activeQuote = quote {
                if character == activeQuote {
                    quote = nil
                } else {
                    current.append(character)
                }
                continue
            }

            if character == "'" || character == "\"" {
                quote = character
                continue
            }

            if character.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) {
                if !current.isEmpty {
                    tokens.append(current)
                    current.removeAll(keepingCapacity: true)
                }
                continue
            }

            current.append(character)
        }

        if isEscaping {
            current.append("\\")
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }
}
