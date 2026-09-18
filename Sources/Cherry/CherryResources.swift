import Foundation

enum CherryResources {
    static let bundle: Bundle = {
        // Native SwiftPM's generated accessor searches the executable bundle's
        // root, but signed macOS apps store resources in Contents/Resources.
        if let url = Bundle.main.resourceURL?.appendingPathComponent("Cherry_Cherry.bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return Bundle.module
    }()
}
