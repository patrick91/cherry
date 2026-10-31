import CherryControl
import Combine
import Foundation
import os

/// Home: each Mac's place for terminals that belong to no project. It is
/// the window of that Mac's home folder, so its key is that folder's (This
/// Mac's path, a device's `device:<uuid>:<its home>`) and its tabs, saved
/// state, sessions and windows work as any project window's. It has no
/// project features: no commands (not even its cherry.toml's), no to-dos,
/// and it is named "Home" wherever its project's name would show
/// (`CherryProject.name`, `RepositoryWorkspace.repositoryName`). Go to Home
/// (⇧⌘H) and New Terminal in Home (⌥⌘T) reach it from anywhere
/// (`ProjectWindowRegistry.showHome`, `newTerminalInHome`), a launch with no
/// project opens it, and the Omni bar lists each Mac's Home first among its
/// projects.
enum HomePlace {
    static let name = "Home"
    static let symbol = "house"

    private static let deviceHomeDirectories = OSAllocatedUnfairLock<[UUID: String]>(initialState: [:])
    @MainActor private static var deviceHomesSubscription: AnyCancellable?

    /// This Mac's home folder, standardized.
    static let localHomeDirectory = standardized(NSHomeDirectory())

    /// This Mac's Home: the key of its home folder's window.
    static var thisMacKey: String { localHomeDirectory }

    /// The home folder of each device, as the app's device store knows it
    /// (`follow(_:)`); none in tests.
    static var deviceHomes: [UUID: String] {
        get { deviceHomeDirectories.withLock { $0 } }
        set { deviceHomeDirectories.withLock { $0 = newValue } }
    }

    /// Keeps `deviceHomes` to what `store` knows. The app follows its own
    /// store; tests never call it.
    @MainActor
    static func follow(_ store: RemoteDeviceStore) {
        deviceHomesSubscription = store.$devices.sink { devices in
            var homes: [UUID: String] = [:]
            for device in devices {
                if let home = device.homeDirectory?.nilIfEmpty { homes[device.id] = home }
            }
            deviceHomes = homes
        }
    }

    /// The Home of `machine`: nil for a device whose home folder is not
    /// known yet.
    static func key(on machine: ProjectSwitcherModel.Machine) -> String? {
        key(on: machine, deviceHomes: deviceHomes)
    }

    /// Whether `key` (a project location key) is a Mac's Home: This Mac's
    /// when it names `localHome`, a device's when it names its home in
    /// `deviceHomes` (tests give their own).
    static func isHome(
        _ key: String?,
        localHome: String = localHomeDirectory,
        deviceHomes: [UUID: String] = deviceHomes
    ) -> Bool {
        guard let key, !key.isEmpty else { return false }
        let location = ProjectLocation(key: key)
        if let deviceID = location.deviceID {
            guard let home = deviceHomes[deviceID] else { return false }
            return ProjectLocation.remote(deviceID: deviceID, path: home).path == location.path
        }
        let home = localHome == localHomeDirectory ? localHome : standardized(localHome)
        return standardized(key) == home
    }

    /// The Home of `machine` given each device's home folder: nil for a
    /// device whose home is not known.
    static func key(on machine: ProjectSwitcherModel.Machine, deviceHomes: [UUID: String]) -> String? {
        switch machine {
        case .thisMac:
            thisMacKey
        case .device(let id):
            deviceHomes[id].map { ProjectLocation.remote(deviceID: id, path: $0).key }
        }
    }

    private static func standardized(_ path: String) -> String {
        URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path
    }
}
