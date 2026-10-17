import Foundation

/// Extracts stable task names from the terminal titles emitted by agent TUIs.
/// Activity glyphs and project names are chrome; the sidebar should display the
/// task identity while keeping those signals in their existing dedicated UI.
enum AgentTerminalTitleParser {
    static func taskTitle(
        from rawTitle: String,
        brand: AgentToolBrand?,
        projectNames: Set<String>,
        agentName: String?
    ) -> String? {
        guard let brand else { return nil }

        let normalizedProjectNames = Set(projectNames.compactMap(normalizedLookupValue))
        let candidate: String?
        switch brand {
        case .codex:
            candidate = codexTaskTitle(from: rawTitle, projectNames: normalizedProjectNames)
        case .claude:
            candidate = claudeTaskTitle(from: rawTitle)
        case .pi:
            candidate = piTaskTitle(from: rawTitle, agentName: agentName)
        case .openCode:
            candidate = openCodeTaskTitle(from: rawTitle)
        case .amp, .gemini:
            // Their title formats are not known yet: a title that is only the
            // program's or the folder's name would replace the agent's name.
            candidate = nil
        }

        guard let candidate = normalizedDisplayValue(candidate) else { return nil }
        let lookupValue = candidate.lowercased()
        let genericTitles = Set([
            brand.displayName.lowercased(),
            "\(brand.displayName.lowercased()) code",
            agentName.flatMap(normalizedLookupValue)
        ].compactMap { $0 })

        guard !genericTitles.contains(lookupValue),
              !normalizedProjectNames.contains(lookupValue),
              lookupValue != "renaming...",
              lookupValue != "action required",
              !candidate.hasPrefix("~"),
              !candidate.hasPrefix("/")
        else {
            return nil
        }

        return String(candidate.prefix(80))
    }

    private static func codexTaskTitle(
        from rawTitle: String,
        projectNames: Set<String>
    ) -> String? {
        guard let title = normalizedDisplayValue(rawTitle) else { return nil }
        // Current Codex defaults include the project as a separate title item.
        // Requiring that separator avoids treating pre-0.154 activity titles such
        // as `⠹ cherry` (which contain only the project) as task names.
        guard title.contains(" | ") else { return nil }
        var parts = title.components(separatedBy: " | ")
            .compactMap(normalizedDisplayValue)

        // The new default is activity, thread-name, project-name. Only consume
        // that shape: custom title layouts can contain model/status fields that
        // should not be mistaken for a task name.
        guard let last = parts.last,
              let lookupValue = normalizedLookupValue(last),
              projectNames.contains(lookupValue)
        else {
            return nil
        }
        parts.removeLast()

        if let first = parts.first,
           first == "[ ! ] Action Required" || first == "[ . ] Action Required" {
            parts.removeFirst()
        }

        guard !parts.isEmpty else { return nil }
        return droppingEdgeActivityGlyphs(parts.joined(separator: " | "), brand: .codex)
    }

    private static func claudeTaskTitle(from rawTitle: String) -> String? {
        guard let title = normalizedDisplayValue(rawTitle) else { return nil }
        return droppingEdgeActivityGlyphs(title, brand: .claude)
    }

    /// Pi's own title is `π - <session name> - <folder>`, or `π - <folder>`
    /// while the session has no name (a Pi built under another app name puts
    /// that name first: taken as such when it is the agent's name). An
    /// extension can set any other title (`ctx.ui.setTitle`), which is taken
    /// whole. A spinner extension's braille frame at the start is chrome.
    private static func piTaskTitle(from rawTitle: String, agentName: String?) -> String? {
        guard let title = droppingEdgeActivityGlyphs(rawTitle, brand: .pi) else { return nil }
        let parts = title.components(separatedBy: " - ")
        let prefixes = piTitlePrefixes.union([normalizedLookupValue(agentName)].compactMap { $0 })
        guard let first = normalizedLookupValue(parts.first),
              prefixes.contains(first)
        else {
            return title
        }
        // `π - <folder>`: the session has no name yet.
        guard parts.count >= 3 else { return nil }
        return normalizedDisplayValue(parts.dropFirst().dropLast().joined(separator: " - "))
    }

    private static let piTitlePrefixes: Set<String> = ["π", "pi"]

    /// OpenCode's title is `OC | <session title>` once the session has a
    /// title (`oc | …` before 1.0.147; cut to 37 characters and `…` past
    /// 40), else `OpenCode`. The same prefix names its full-screen views
    /// (`diff`, `stats`, `storybook`) and, in 1.x, a subagent's session it
    /// shows (`<description> (@<agent> subagent)`): neither is this tab's
    /// task. No activity glyphs.
    private static func openCodeTaskTitle(from rawTitle: String) -> String? {
        guard let title = normalizedDisplayValue(rawTitle),
              title.lowercased().hasPrefix(openCodeTitlePrefix)
        else { return nil }
        let task = String(title.dropFirst(openCodeTitlePrefix.count))
        guard !openCodeViewTitles.contains(task.lowercased()),
              task.range(of: #" \(@[^()]+ subagent\)$"#, options: .regularExpression) == nil
        else { return nil }
        return task
    }

    private static let openCodeTitlePrefix = "oc | "
    private static let openCodeViewTitles: Set<String> = ["diff", "stats", "storybook"]

    private static func droppingEdgeActivityGlyphs(
        _ rawValue: String,
        brand: AgentToolBrand
    ) -> String? {
        guard var value = normalizedDisplayValue(rawValue) else { return nil }

        if let firstScalar = value.unicodeScalars.first,
           isBraille(firstScalar) {
            let scalarEnd = value.unicodeScalars.index(after: value.unicodeScalars.startIndex)
            value.removeSubrange(value.startIndex..<scalarEnd)
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        } else if brand == .claude,
                  let first = value.first,
                  claudeActivityGlyphs.contains(first) {
            value.removeFirst()
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        if let lastScalar = value.unicodeScalars.last,
           isBraille(lastScalar) {
            let scalarIndex = value.unicodeScalars.index(before: value.unicodeScalars.endIndex)
            value.removeSubrange(scalarIndex..<value.endIndex)
        }

        return normalizedDisplayValue(value)
    }

    private static let claudeActivityGlyphs: Set<Character> = ["✳", "✶", "✻", "✢", "*", "·"]

    private static func isBraille(_ scalar: Unicode.Scalar) -> Bool {
        (0x2800...0x28FF).contains(Int(scalar.value))
    }

    private static func normalizedLookupValue(_ value: String?) -> String? {
        normalizedDisplayValue(value)?.lowercased()
    }

    private static func normalizedDisplayValue(_ value: String?) -> String? {
        guard let value else { return nil }
        let withoutControls = value.unicodeScalars.map { scalar in
            CharacterSet.controlCharacters.contains(scalar) ? " " : String(scalar)
        }.joined()
        let normalized = withoutControls
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        return normalized.isEmpty ? nil : normalized
    }
}
