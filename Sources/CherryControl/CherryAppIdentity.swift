import Foundation

/// Bundle configuration shared by the app and its embedded MCP executable.
/// Alternate app builds must keep their private data and deep links separate.
public struct CherryAppIdentity: Equatable, Sendable {
    public let applicationSupportName: String
    public let urlScheme: String

    public static let current = CherryAppIdentity(
        infoDictionary: configurationInfo(
            bundle: .main,
            executableURL: Bundle.main.executableURL
        )
    )

    public init(infoDictionary: [String: Any] = [:]) {
        let supportName = (infoDictionary["CherryApplicationSupportName"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if let supportName, !supportName.isEmpty,
           supportName != ".", supportName != "..",
           !supportName.contains("/"), !supportName.contains("\0") {
            applicationSupportName = supportName
        } else {
            applicationSupportName = "Cherry"
        }

        let scheme = (infoDictionary["CherryURLScheme"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if let scheme,
           scheme.range(of: "^[a-z][a-z0-9+.-]*$", options: .regularExpression) != nil {
            urlScheme = scheme
        } else {
            urlScheme = "cherry"
        }
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
