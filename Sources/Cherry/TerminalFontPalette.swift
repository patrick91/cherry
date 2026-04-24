import AppKit

enum TerminalFontPalette {
    private static let preferredNerdFamilies = [
        "Symbols Nerd Font Mono",
        "Symbols Nerd Font",
        "JetBrainsMono Nerd Font Mono",
        "JetBrainsMonoNL Nerd Font Mono",
        "MesloLGS NF",
        "CaskaydiaCove Nerd Font Mono",
        "CascadiaCode Nerd Font Mono",
        "Hack Nerd Font Mono",
        "FiraCode Nerd Font Mono",
        "FiraMono Nerd Font Mono",
        "SauceCodePro Nerd Font Mono",
        "RobotoMono Nerd Font Mono",
        "UbuntuMono Nerd Font Mono",
        "Iosevka Nerd Font Mono"
    ]

    static func regular(size: CGFloat) -> NSFont {
        terminalFont(size: size, faces: ["Regular", "Book", "Medium"])
    }

    static func medium(size: CGFloat) -> NSFont {
        terminalFont(size: size, faces: ["Medium", "Regular", "SemiBold"])
    }

    static func semibold(size: CGFloat) -> NSFont {
        terminalFont(size: size, faces: ["SemiBold", "Bold", "Medium", "Regular"])
    }

    static func cellWidth(for font: NSFont) -> CGFloat {
        cellWidth(for: [font])
    }

    static func cellWidth(for fonts: [NSFont]) -> CGFloat {
        let probeCharacters = ["W", "m", "0", "─", "│", "┌", "█"]
        let measuredWidth = fonts.flatMap { font in
            probeCharacters.map { character in
                character.size(withAttributes: [.font: font]).width
            }
        }
        .max() ?? 0

        return max(7.8, ceil(measuredWidth))
    }

    static func preferredNerdFontFamilies(from families: [String]) -> [String] {
        var familiesByLowercase: [String: String] = [:]
        for family in families {
            familiesByLowercase[family.lowercased()] = family
        }

        var selected: [String] = []
        var seen = Set<String>()

        func append(_ family: String) {
            let key = family.lowercased()
            guard !seen.contains(key) else { return }
            selected.append(family)
            seen.insert(key)
        }

        for family in preferredNerdFamilies {
            if let installed = familiesByLowercase[family.lowercased()] {
                append(installed)
            }
        }

        for family in families.sorted() {
            let lowercased = family.lowercased()
            if lowercased.contains("nerd font mono") || lowercased.contains(" nerd font") || lowercased.hasSuffix(" nf") {
                append(family)
            }
        }

        return selected
    }

    private static func terminalFont(size: CGFloat, faces: [String]) -> NSFont {
        let nerdFamilies = preferredNerdFontFamilies(from: NSFontManager.shared.availableFontFamilies)
        let preferredFont = nerdFamilies
            .lazy
            .compactMap { font(inFamily: $0, size: size, faces: faces) }
            .first
        let baseFont = preferredFont ?? NSFont.monospacedSystemFont(ofSize: size, weight: .regular)
        return addingNerdFallbacks(to: baseFont, families: nerdFamilies, size: size)
    }

    private static func font(inFamily family: String, size: CGFloat, faces: [String]) -> NSFont? {
        guard let members = NSFontManager.shared.availableMembers(ofFontFamily: family) else { return nil }

        for face in faces {
            if let font = font(inMembers: members, size: size, matchingFace: face) {
                return font
            }
        }

        return members
            .compactMap { member -> NSFont? in
                guard member.count >= 2,
                      let fontName = member[0] as? String,
                      let faceName = member[1] as? String,
                      !faceName.localizedCaseInsensitiveContains("Italic") else {
                    return nil
                }

                return NSFont(name: fontName, size: size)
            }
            .first
    }

    private static func font(inMembers members: [[Any]], size: CGFloat, matchingFace face: String) -> NSFont? {
        members
            .compactMap { member -> NSFont? in
                guard member.count >= 2,
                      let fontName = member[0] as? String,
                      let faceName = member[1] as? String,
                      faceName.caseInsensitiveCompare(face) == .orderedSame else {
                    return nil
                }

                return NSFont(name: fontName, size: size)
            }
            .first
    }

    private static func addingNerdFallbacks(to font: NSFont, families: [String], size: CGFloat) -> NSFont {
        let cascadeList = families.map { family in
            NSFontDescriptor(fontAttributes: [.family: family])
        }
        guard !cascadeList.isEmpty else { return font }

        let descriptor = font.fontDescriptor.addingAttributes([.cascadeList: cascadeList])
        return NSFont(descriptor: descriptor, size: size) ?? font
    }
}
