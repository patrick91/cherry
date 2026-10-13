import CherryControl
import Foundation

/// The user's other Macs (docs/specs/remote-devices.md) as the Omni bar
/// and Settings › Macs know them (`Device`, from cached state), and what
/// opening a project or acting on a Mac does (`Action`, run by
/// `ProjectSwitcherActions`). The Omni bar offers a device's actions as
/// its Mac row's ⌘K actions (`OmniProviders.macActions`).
enum TitlebarProjectMenuModel {
    /// A device and what is known of it now.
    struct Device: Equatable {
        var device: RemoteDevice
        var state: RemoteDeviceConnectionState
        /// Its host's sessions as last listed (every owner's).
        var sessions: [HostedSessionInfo]
        /// The build of the cherry-host this Cherry bundles (nil until
        /// read): an older install there offers Update Session Host….
        var bundledBuild: String? = nil

        /// Update Session Host… is offered: the install there is an older
        /// build than this Cherry's, or one without Ghostty's terminfo and
        /// shell integration (installed before phase 3), or its host speaks
        /// another protocol.
        var offersHostUpdate: Bool {
            switch state {
            case .incompatible, .hostMissing: return true
            default:
                return device.hostIsOlder(thanBundled: bundledBuild)
                    || (bundledBuild != nil && device.installedBuild != nil && !device.installedResources)
            }
        }

        /// "Reinstall Session Host…" when the one it names is gone.
        var hostUpdateTitle: String {
            if case .hostMissing = state { return "Reinstall Session Host…" }
            return "Update Session Host…"
        }
    }

    enum Action: Equatable {
        case openProject(String)
        case openDeviceProject(deviceID: UUID, path: String)
        /// The Persistent Sessions sheet on that host.
        case openDeviceSessions(UUID)
        case openDeviceHome(UUID)
        case addDeviceProject(UUID)
        case hideDeviceProject(deviceID: UUID, path: String)
        case reconnectDevice(UUID)
        case trustDeviceIdentity(UUID)
        /// Update Session Host…: install this Cherry's there.
        case updateDeviceHost(UUID)
        /// Set Up Cherry MCP on <Mac>…: registers Cherry MCP with the
        /// agents there, when the user confirms (phase 4b).
        case setUpDeviceMCP(UUID)
        case renameDevice(UUID)
        case removeDevice(UUID)
        case addMac
    }
}
