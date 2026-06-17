import Foundation

enum NixShellKind: String, Equatable {
    case shell
    case develop
    case legacyShell

    var displayName: String {
        switch self {
        case .shell:
            "nix shell"
        case .develop:
            "nix develop"
        case .legacyShell:
            "nix-shell"
        }
    }
}

struct NixShellPackageReference: Equatable, Identifiable {
    let rawValue: String

    var id: String { rawValue }

    var displayName: String {
        Self.displayName(for: rawValue)
    }

    private static func displayName(for value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return value }

        if let hash = trimmed.lastIndex(of: "#") {
            let attr = trimmed[trimmed.index(after: hash)...]
            if !attr.isEmpty {
                return lastAttributeComponent(String(attr))
            }
        }

        let lastPathComponent = URL(fileURLWithPath: trimmed).lastPathComponent
        let candidate = lastPathComponent.isEmpty ? trimmed : lastPathComponent
        return lastAttributeComponent(candidate)
    }

    private static func lastAttributeComponent(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !trimmed.isEmpty else { return value }
        return trimmed.split(separator: ".").last.map(String.init) ?? trimmed
    }
}

struct NixShellEnvironment: Equatable {
    let kind: NixShellKind
    let command: String
    let packageReferences: [NixShellPackageReference]

    var displayName: String {
        kind.displayName
    }

    var packageSummary: String? {
        guard !packageReferences.isEmpty else { return nil }
        let displayed = packageReferences.prefix(3).map(\.displayName)
        if packageReferences.count <= displayed.count {
            return displayed.joined(separator: ", ")
        }
        return displayed.joined(separator: ", ") + ", +\(packageReferences.count - displayed.count)"
    }

    var packageList: String {
        packageReferences.map(\.rawValue).joined(separator: "\n")
    }

    var tooltip: String {
        if let packageSummary {
            return "\(displayName): \(packageSummary)"
        }
        return displayName
    }
}

enum NixShellCommandParser {
    static func environment(from command: String) -> NixShellEnvironment? {
        let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedCommand.isEmpty else { return nil }

        let tokens = effectiveCommandTokens(tokens(from: trimmedCommand))
        guard let firstToken = tokens.first else { return nil }

        switch normalizedExecutableName(firstToken) {
        case "nix":
            return nixEnvironment(from: tokens, command: trimmedCommand)
        case "nix-shell":
            return legacyEnvironment(from: tokens, command: trimmedCommand)
        default:
            return nil
        }
    }

    private static func nixEnvironment(from tokens: [String], command: String) -> NixShellEnvironment? {
        guard let subcommandIndex = nixSubcommandIndex(in: tokens) else { return nil }

        let kind: NixShellKind
        switch tokens[subcommandIndex].lowercased() {
        case "shell":
            kind = .shell
        case "develop":
            kind = .develop
        default:
            return nil
        }

        let packages = packageReferences(
            fromNixArguments: Array(tokens.dropFirst(subcommandIndex + 1)),
            commandTerminators: ["--command", "--run", "-c"]
        )
        return NixShellEnvironment(kind: kind, command: command, packageReferences: packages)
    }

    private static func legacyEnvironment(from tokens: [String], command: String) -> NixShellEnvironment {
        NixShellEnvironment(
            kind: .legacyShell,
            command: command,
            packageReferences: legacyPackageReferences(from: Array(tokens.dropFirst()))
        )
    }

    private static func nixSubcommandIndex(in tokens: [String]) -> Int? {
        var index = 1
        while index < tokens.count {
            let token = tokens[index].lowercased()
            if token == "shell" || token == "develop" {
                return index
            }
            guard token != "--", token.hasPrefix("-") else { return nil }
            index += 1 + nixGlobalOptionValueCount(token)
        }
        return nil
    }

    private static func packageReferences(
        fromNixArguments tokens: [String],
        commandTerminators: Set<String>
    ) -> [NixShellPackageReference] {
        var references: [NixShellPackageReference] = []
        var index = 0

        while index < tokens.count {
            let token = tokens[index]
            let lowered = token.lowercased()
            if commandTerminators.contains(lowered) {
                break
            }
            if token == "--" {
                index += 1
                continue
            }
            if token.hasPrefix("-") {
                index += 1 + nixShellOptionValueCount(lowered)
                continue
            }
            references.append(NixShellPackageReference(rawValue: token))
            index += 1
        }

        return references
    }

    private static func legacyPackageReferences(from tokens: [String]) -> [NixShellPackageReference] {
        var references: [NixShellPackageReference] = []
        var index = 0

        while index < tokens.count {
            let token = tokens[index]
            let lowered = token.lowercased()
            if lowered == "--run" || lowered == "--command" {
                break
            }
            if lowered == "-p" || lowered == "--packages" {
                index += 1
                while index < tokens.count, !tokens[index].hasPrefix("-") {
                    references.append(NixShellPackageReference(rawValue: tokens[index]))
                    index += 1
                }
                continue
            }
            if lowered == "-a" || lowered == "--attr" {
                if index + 1 < tokens.count {
                    references.append(NixShellPackageReference(rawValue: tokens[index + 1]))
                }
                index += 2
                continue
            }
            if token.hasPrefix("-") {
                index += 1 + legacyOptionValueCount(lowered)
                continue
            }
            references.append(NixShellPackageReference(rawValue: token))
            index += 1
        }

        return references
    }

    private static func effectiveCommandTokens(_ tokens: [String]) -> [String] {
        var remaining = tokens

        while let first = remaining.first {
            let name = normalizedExecutableName(first)

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

            if name == "arch" {
                remaining.removeFirst()
                if let next = remaining.first, next.hasPrefix("-") {
                    remaining.removeFirst()
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

    private static func tokens(from command: String) -> [String] {
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

            if character == "\\" {
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

            if character == "\"" || character == "'" {
                quote = character
                continue
            }

            if character.isWhitespace {
                appendCurrentToken(&tokens, &current)
            } else {
                current.append(character)
            }
        }

        if isEscaping {
            current.append("\\")
        }
        appendCurrentToken(&tokens, &current)

        return tokens
    }

    private static func appendCurrentToken(_ tokens: inout [String], _ current: inout String) {
        guard !current.isEmpty else { return }
        tokens.append(current)
        current.removeAll(keepingCapacity: true)
    }

    private static func normalizedExecutableName(_ value: String) -> String {
        var name = URL(fileURLWithPath: value).lastPathComponent.lowercased()
        if name.hasSuffix(".exe") {
            name.removeLast(4)
        }
        return name
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

    private static func nixGlobalOptionValueCount(_ option: String) -> Int {
        if option.contains("=") { return 0 }
        return nixGlobalOptionsTakingTwoValues.contains(option) ? 2 :
            (nixGlobalOptionsTakingOneValue.contains(option) ? 1 : 0)
    }

    private static func nixShellOptionValueCount(_ option: String) -> Int {
        if option.contains("=") { return 0 }
        if nixShellOptionsTakingTwoValues.contains(option) { return 2 }
        if nixShellOptionsTakingOneValue.contains(option) { return 1 }
        return 0
    }

    private static func legacyOptionValueCount(_ option: String) -> Int {
        if option.contains("=") { return 0 }
        return legacyOptionsTakingOneValue.contains(option) ? 1 : 0
    }

    private static let wrapperCommands: Set<String> = [
        "command", "exec", "noglob", "time"
    ]

    private static let optionsTakingValue: Set<String> = [
        "-C", "-E", "-H", "-P", "-S", "-c", "-g", "-h", "-p", "-u",
        "--cache", "--cwd", "--directory", "--package", "--prefix", "--registry",
        "--shell", "--user", "--userconfig"
    ]

    private static let nixGlobalOptionsTakingOneValue: Set<String> = [
        "--access-tokens", "--builders", "--commit-lock-file-summary",
        "--cores", "--eval-store", "--experimental-features", "--extra-experimental-features",
        "--flake-registry", "--log-format", "--max-jobs", "--option", "--store", "-j"
    ]

    private static let nixGlobalOptionsTakingTwoValues: Set<String> = [
        "--option"
    ]

    private static let nixShellOptionsTakingOneValue: Set<String> = [
        "--command", "--expr", "--file", "--inputs-from", "--profile", "--redirect",
        "--run", "-c", "-f"
    ]

    private static let nixShellOptionsTakingTwoValues: Set<String> = [
        "--override-input", "--option"
    ]

    private static let legacyOptionsTakingOneValue: Set<String> = [
        "--attr", "--command", "--expr", "--indirect", "--run", "-a", "-e", "-i"
    ]
}
