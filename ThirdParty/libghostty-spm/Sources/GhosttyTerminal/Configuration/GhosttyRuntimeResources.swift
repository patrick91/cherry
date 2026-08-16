import Darwin
import Foundation

/// Runtime assets required by Ghostty's exec backend.
public enum GhosttyRuntimeResources {
    /// The package-bundled Ghostty resource directory.
    public static var directoryURL: URL? {
        Bundle.module.url(forResource: "Ghostty", withExtension: nil)
    }

    /// The compiled terminfo database exported to child shells by Ghostty.
    public static var terminfoDirectoryURL: URL? {
        Bundle.module.url(forResource: "terminfo", withExtension: nil)
    }

    static func configureEnvironment() {
        guard let path = directoryURL?.path else { return }
        setenv("GHOSTTY_RESOURCES_DIR", path, 1)
    }
}
