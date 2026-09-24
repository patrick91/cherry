import Foundation
import os

/// Bundle configuration shared by the app and its embedded MCP executable.
/// Alternate app builds must keep their private data and deep links separate.
public struct CherryAppIdentity: Equatable, Sendable {
    public static let defaultApplicationSupportName = "Cherry"
    public static let defaultURLScheme = "cherry"
    static let applicationSupportNameKey = "CherryApplicationSupportName"
    static let urlSchemeKey = "CherryURLScheme"

    public let applicationSupportName: String
    public let urlScheme: String

    public static let current = CherryAppIdentity(
        infoDictionary: configurationInfo(
            bundle: .main,
            executableURL: Bundle.main.executableURL
        )
    )

    private static let logger = Logger(subsystem: "Cherry", category: "AppIdentity")

    /// `warn` receives one message per Info.plist value that is present but
    /// unusable. Such a build falls back to the main Cherry's identity, so it
    /// shares that app's data and MCP name; the default logs it loudly.
    public init(
        infoDictionary: [String: Any] = [:],
        warn: (String) -> Void = CherryAppIdentity.logWarning
    ) {
        let rawSupportName = infoDictionary[Self.applicationSupportNameKey]
        let supportName = (rawSupportName as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let supportName, !supportName.isEmpty,
           supportName != ".", supportName != "..",
           !supportName.contains("/"), !supportName.contains("\0") {
            applicationSupportName = supportName
            if supportName != Self.defaultApplicationSupportName,
               supportName.caseInsensitiveCompare(Self.defaultApplicationSupportName) == .orderedSame {
                warn(
                    "\(Self.applicationSupportNameKey) \"\(supportName)\" differs from "
                        + "\"\(Self.defaultApplicationSupportName)\" only by case; on a case-insensitive "
                        + "volume this build shares the main Cherry app's Application Support data."
                )
            }
        } else {
            applicationSupportName = Self.defaultApplicationSupportName
            if let rawSupportName {
                warn(
                    "Ignoring invalid \(Self.applicationSupportNameKey) \(Self.describe(rawSupportName)) "
                        + "in Info.plist (it must be a non-empty folder name without \"/\"); using "
                        + "\"\(Self.defaultApplicationSupportName)\", so this build shares the main "
                        + "Cherry app's Application Support data."
                )
            }
        }

        let rawScheme = infoDictionary[Self.urlSchemeKey]
        let scheme = (rawScheme as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let scheme,
           scheme.range(of: "^[a-z][a-z0-9+.-]*$", options: .regularExpression) != nil {
            urlScheme = scheme
        } else {
            urlScheme = Self.defaultURLScheme
            if let rawScheme {
                warn(
                    "Ignoring invalid \(Self.urlSchemeKey) \(Self.describe(rawScheme)) in Info.plist "
                        + "(it must match ^[a-z][a-z0-9+.-]*$); using \"\(Self.defaultURLScheme)\", so this "
                        + "build's deep links and MCP server name are the main Cherry app's."
                )
            }
        }
    }

    public static func logWarning(_ message: String) {
        logger.warning("\(message, privacy: .public)")
    }

    private static func describe(_ value: Any) -> String {
        guard let string = value as? String else { return "of type \(type(of: value))" }
        return "\"\(string.debugDescription.dropFirst().dropLast())\""
    }

    public static func configurationInfo(bundle: Bundle, executableURL: URL?) -> [String: Any] {
        if bundle.bundleURL.pathExtension.lowercased() == "app" {
            return bundle.infoDictionary ?? [:]
        }

        // Bundle.main can be the standalone helper instead of its containing app.
        // Resolve the app's Info.plist so app and MCP links use the same scheme.
        var directory = executableURL?.deletingLastPathComponent()
        while let candidate = directory, candidate.path != "/" {
            if candidate.pathExtension.lowercased() == "app" {
                return Bundle(url: candidate)?.infoDictionary ?? [:]
            }
            directory = candidate.deletingLastPathComponent()
        }
        return bundle.infoDictionary ?? [:]
    }
}
