import Foundation

struct SidebarTerminalPathLabel: Equatable {
    let title: String
    let detail: String?
    let detailIconResourceName: String?
    let leadingIconResourceName: String?
    let leadingIconFallback: String?
    let leadingIconRendersAsTemplate: Bool

    init(
        title: String,
        detail: String? = nil,
        detailIconResourceName: String? = nil,
        leadingIconResourceName: String? = nil,
        leadingIconFallback: String? = nil,
        leadingIconRendersAsTemplate: Bool = false
    ) {
        self.title = title
        self.detail = detail
        self.detailIconResourceName = detailIconResourceName
        self.leadingIconResourceName = leadingIconResourceName
        self.leadingIconFallback = leadingIconFallback
        self.leadingIconRendersAsTemplate = leadingIconRendersAsTemplate
    }
}

enum SidebarTerminalPathFormatter {
    static func label(
        for workingDirectory: String,
        mode: SidebarTerminalPathDisplayMode,
        homeDirectory: String = NSHomeDirectory()
    ) -> SidebarTerminalPathLabel {
        switch mode {
        case .repoFocused:
            if let github = githubRepositoryLabel(for: workingDirectory, homeDirectory: homeDirectory) {
                return github
            }
            return smartInitialsLabel(for: workingDirectory, homeDirectory: homeDirectory)
        case .smartInitials:
            return smartInitialsLabel(for: workingDirectory, homeDirectory: homeDirectory)
        case .fullPath:
            return .init(title: displayPath(workingDirectory, homeDirectory: homeDirectory))
        }
    }

    static func displayPath(_ path: String, homeDirectory: String = NSHomeDirectory()) -> String {
        let normalizedPath = normalizedAbsolutePath(path, homeDirectory: homeDirectory)
        let normalizedHome = normalizedAbsolutePath(homeDirectory, homeDirectory: homeDirectory)
        if normalizedPath == normalizedHome {
            return "~"
        }
        if normalizedPath.hasPrefix(normalizedHome + "/") {
            return "~/" + normalizedPath.dropFirst(normalizedHome.count + 1)
        }
        return normalizedPath
    }

    static func shouldUseWorkingDirectoryLabel(
        title: String,
        workingDirectory: String,
        homeDirectory: String = NSHomeDirectory()
    ) -> Bool {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedTitle == displayPath(workingDirectory, homeDirectory: homeDirectory) {
            return true
        }

        return trimmedTitle.hasPrefix("~/") ||
            trimmedTitle.hasPrefix("/") ||
            trimmedTitle.hasPrefix(".../") ||
            trimmedTitle.hasPrefix("…/")
    }

    private static func githubRepositoryLabel(
        for path: String,
        homeDirectory: String
    ) -> SidebarTerminalPathLabel? {
        let components = relativeComponents(for: path, homeDirectory: homeDirectory)
        guard components.count >= 3,
              components[0].caseInsensitiveCompare("github") == .orderedSame
        else {
            return nil
        }

        let owner = components[1]
        let repo = components[2]
        let remaining = Array(components.dropFirst(3))
        let title = ([repo] + remaining).joined(separator: "/")
        return .init(title: title, detail: "\(owner)/\(repo)", detailIconResourceName: "github")
    }

    private static func smartInitialsLabel(
        for path: String,
        homeDirectory: String
    ) -> SidebarTerminalPathLabel {
        let displayPath = displayPath(path, homeDirectory: homeDirectory)
        let usesTilde = displayPath == "~" || displayPath.hasPrefix("~/")
        let prefix = usesTilde ? "~" : (displayPath.hasPrefix("/") ? "/" : "")
        let trimmed = displayPath
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .replacingOccurrences(of: "~/", with: "")
        let components = trimmed
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)

        guard components.count > 3 else {
            return .init(title: displayPath)
        }

        let firstKeptIndex = max(0, components.count - 3)
        let abbreviated = components.enumerated().map { index, component in
            index < firstKeptIndex ? String(component.prefix(1)) : component
        }
        let separator = prefix == "/" ? "" : "/"
        return .init(title: prefix + separator + abbreviated.joined(separator: "/"))
    }

    private static func relativeComponents(for path: String, homeDirectory: String) -> [String] {
        let normalizedPath = normalizedAbsolutePath(path, homeDirectory: homeDirectory)
        let normalizedHome = normalizedAbsolutePath(homeDirectory, homeDirectory: homeDirectory)
        guard normalizedPath.hasPrefix(normalizedHome + "/") else { return [] }
        return normalizedPath
            .dropFirst(normalizedHome.count + 1)
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private static func normalizedAbsolutePath(_ path: String, homeDirectory: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        let expanded: String
        if trimmed == "~" {
            expanded = homeDirectory
        } else if trimmed.hasPrefix("~/") {
            expanded = homeDirectory + "/" + trimmed.dropFirst(2)
        } else {
            expanded = NSString(string: trimmed).expandingTildeInPath
        }
        return URL(fileURLWithPath: expanded).standardizedFileURL.path
    }
}
