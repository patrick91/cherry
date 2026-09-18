import Darwin
import Foundation

/// Runtime assets required by Ghostty's exec backend.
public enum GhosttyRuntimeResources {
    private static let resourceBundle: Bundle = {
        // SwiftPM's native builder searches the app root before an absolute
        // build-directory fallback. Packaged macOS apps use Contents/Resources.
        if let url = Bundle.main.resourceURL?.appendingPathComponent("GhosttyKit_GhosttyTerminal.bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return Bundle.module
    }()

    /// The package-bundled Ghostty resource directory.
    public static var directoryURL: URL? {
        resourceBundle.url(forResource: "Ghostty", withExtension: nil)
    }

    /// The compiled terminfo database exported to child shells by Ghostty.
    public static var terminfoDirectoryURL: URL? {
        resourceBundle.url(forResource: "terminfo", withExtension: nil)
    }

    static func configureEnvironment() {
        guard let path = directoryURL?.path else { return }
        setenv("GHOSTTY_RESOURCES_DIR", path, 1)
    }
}
