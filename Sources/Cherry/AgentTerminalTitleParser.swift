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
        case .amp, .gemini, .openCode, .pi:
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
