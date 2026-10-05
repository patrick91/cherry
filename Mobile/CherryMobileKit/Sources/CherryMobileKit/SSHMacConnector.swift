import Foundation

/// Reaches a real Mac over SSH and runs Cherry's helpers there
/// (docs/specs/ios-app.md, Transport). P0 placeholder: the SSH transport
/// replaces this body.
public struct SSHMacConnector: MacConnector {
    public let identity: any DeviceIdentity

    public init(identity: any DeviceIdentity) {
        self.identity = identity
    }

    public func connect(to endpoint: MacEndpoint) async throws -> any MacConnection {
        throw MacConnectionError.failed("Connecting over SSH isn't built yet.")
    }
}

/// This device's Ed25519 key, kept in the Keychain. P0 placeholder: the
/// SSH transport replaces this body.
public struct KeychainDeviceIdentity: DeviceIdentity {
    public let service: String

    public init(service: String = "dev.patrick.cherry.mobile.ssh-key") {
        self.service = service
    }

    public func publicKey() throws -> String {
        throw MacConnectionError.failed("This device's SSH key isn't built yet.")
    }
}
