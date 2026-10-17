import CherryMobileKit
import Foundation

/// The Macs the app knows, saved in UserDefaults as JSON, and whether the
/// Demo Mac shows. Nothing secret is saved here: the device's key lives in
/// the Keychain.
@MainActor
final class MacStore {
    private let defaults: UserDefaults
    private static let endpointsKey = "macs.v1"
    private static let showsDemoKey = "macs.showsDemo"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var endpoints: [MacEndpoint] {
        get {
            guard let data = defaults.data(forKey: Self.endpointsKey),
                  let endpoints = try? JSONDecoder().decode([MacEndpoint].self, from: data)
            else { return [] }
            return endpoints
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else { return }
            defaults.set(data, forKey: Self.endpointsKey)
        }
    }

    /// On until the user turns it off.
    var showsDemoMac: Bool {
        get { defaults.object(forKey: Self.showsDemoKey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Self.showsDemoKey) }
    }
}
