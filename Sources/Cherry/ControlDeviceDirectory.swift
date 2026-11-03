import CherryControl
import Foundation

/// What the control server knows of the user's other machines (devices,
/// docs/specs/remote-devices.md) for `list_devices` and `add_project`: the
/// app's `RemoteDeviceStore`, or a test's stand-in. It never connects a
/// device or starts a daemon to list one; adding a project runs the same
/// scripts Add Project on <Mac>… and the Omni bar's New folder do, over the
/// device's SSH connection.
@MainActor
struct ControlDeviceDirectory {
    struct Device: Equatable {
        var id: UUID
        var name: String
        var homeDirectory: String?
        /// Its added projects' paths there.
        var projects: [String]
    }

    struct Added: Equatable {
        /// The folder as the device resolved it (`pwd -P`).
        var path: String
        var created: Bool
        var alreadyAdded: Bool
    }

    var devices: @MainActor () -> [Device]
    /// Adds the folder at `path` (absolute) on the device as a project,
    /// making it first (only it) when `create` and it is not there.
    var addProject: @MainActor (_ path: String, _ deviceID: UUID, _ create: Bool) async throws -> Added

    /// No devices (tests' servers, unless they give their own).
    static let none = ControlDeviceDirectory(
        devices: { [] },
        addProject: { _, _, _ in
            throw CherryControlError(code: "device_not_found", message: "Cherry knows no other Macs.")
        }
    )

    /// The app's: `store`'s devices, added through
    /// `RemoteDeviceProjectAdding`.
    static func app(store: RemoteDeviceStore) -> ControlDeviceDirectory {
        ControlDeviceDirectory(
            devices: {
                store.devices.map { device in
                    Device(
                        id: device.id,
                        name: device.name,
                        homeDirectory: device.homeDirectory,
                        projects: device.addedProjects
                    )
                }
            },
            addProject: { path, deviceID, create in
                try await add(path, to: deviceID, create: create, store: store)
            }
        )
    }

    /// Resolves and adds `path`; when it is missing and `create`, makes it
    /// there (`OmniRemoteFolders.create`) and adds it then.
    static func add(
        _ path: String,
        to deviceID: UUID,
        create: Bool,
        store: RemoteDeviceStore,
        resolve: @escaping RemoteDeviceProjectAdding.Resolver = RemoteDeviceProjectAdding.resolveOverSSH,
        makeFolder: @escaping @MainActor (_ path: String, _ device: RemoteDevice) async -> OmniFolderCreation = { path, device in
            let shell = await OmniRemoteFolders.shell(for: device)
            return await OmniRemoteFolders.create(path, on: device.sshDestination, shell: shell)
        }
    ) async throws -> Added {
        guard let device = store.device(id: deviceID) else {
            throw CherryControlError(code: "device_not_found", message: "That Mac is no longer one of your Macs.")
        }
        guard store.canModify else {
            throw CherryControlError(code: "devices_read_only", message: RemoteDeviceStore.readOnlyReason)
        }
        let before = Set(device.addedProjects)
        func added(_ key: String, created: Bool) -> Added {
            let resolved = ProjectLocation(key: key).path
            return Added(path: resolved, created: created, alreadyAdded: before.contains(resolved))
        }
        switch await RemoteDeviceProjectAdding.add(path, to: deviceID, store: store, resolve: resolve) {
        case .success(let key):
            return added(key, created: false)
        case .failure(.ssh(let failure)):
            throw CherryControlError(code: "device_unreachable", message: "\(device.name): \(failure.message)")
        case .failure(.message(let message)):
            guard create else { throw CherryControlError(code: "folder_not_found", message: "\(device.name): \(message)") }
        }
        switch await makeFolder(path, device) {
        case .created:
            break
        case .failed(let message):
            throw CherryControlError(code: "folder_not_created", message: "\(device.name): \(path) could not be made: \(message)")
        }
        switch await RemoteDeviceProjectAdding.add(path, to: deviceID, store: store, resolve: resolve) {
        case .success(let key):
            return added(key, created: true)
        case .failure(let failure):
            throw CherryControlError(code: "folder_not_found", message: "\(device.name): \(failure.message)")
        }
    }
}
