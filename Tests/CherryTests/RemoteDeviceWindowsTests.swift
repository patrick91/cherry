import AppKit
import CherryControl
import Foundation
import Testing
@testable import Cherry

// Several windows of a device's project (#22, docs/specs/remote-devices.md
// "Remote windows"): File › New Window opens another window of the same
// project on that Mac, on the device's one hosting, each window with its
// own use and lease of it; never for a device Cherry no longer knows.
// Inert hostings: nothing connects, and no ssh runs.

/// A device project's window as the app builds it, on `hosting`.
@MainActor
private func deviceWindow(_ key: String, windowID: UUID? = nil, hosting: PersistentHostSessions) -> RepositoryWorkspace {
    RepositoryWorkspace(
        projectRoot: key,
        windowID: windowID,
        backendPolicy: .remote(hosting, settings: { .native }, hostReconnects: nil),
        sessionRestorer: hosting.profile.isKnownDevice
            ? WorkspaceSessionRestorers.hostedByDefault(localSessions: hosting)
            : RemoteDeviceStore.keepingRestorer,
        autoStartCommands: { _ in [] }
    )
}

/// New Window in a device project's window opens another window of that
/// project there (its key, never This Mac's last project), on the same
/// hosting: its one tab runs there, and each window marks the hosting in
/// use and holds its own lease on the device's control connection, so
/// closing one keeps the other's.
@Test @MainActor func RemoteDeviceNewWindowOpensAnotherWindowOfTheSameDeviceProject() async throws {
    let deviceID = UUID()
    let key = ProjectLocation.remote(deviceID: deviceID, path: "/Users/them/work/app").key
    let hosting = inertDeviceHosting("studio-\(deviceID.uuidString.prefix(8))", name: "Studio")
    let registry = ProjectWindowRegistry()
    registry.bringWindowForward = { _ in }
    var opened: [ProjectWindowValue] = []
    registry.newProjectWindowOpener = { opened.append($0) }
    registry.projectWindowOpener = { _ in Issue.record("New Window in a device window opened This Mac's default project") }
    var windows: [(window: NSWindow, repository: RepositoryWorkspace)] = []
    func claim(_ repository: RepositoryWorkspace) -> NSWindow {
        let window = testWindow()
        #expect(registry.register(
            window: window, projectRoot: repository.repositoryRoot, windowID: repository.windowID,
            workspace: repository.workspace, repository: repository, todoStore: nil, chromeState: nil
        ))
        repository.beginRestoringSavedStateIfNeeded(chromeState: nil)
        windows.append((window, repository))
        return window
    }
    func close(_ index: Int) {
        let (window, repository) = windows.remove(at: index)
        registry.unregister(window: window, projectRoot: repository.repositoryRoot)
        repository.closeAllSessions(intent: .windowClosed)
    }
    defer {
        while !windows.isEmpty { close(0) }
    }

    let first = deviceWindow(key, hosting: hosting)
    let firstWindow = claim(first)
    #expect(first.allowsAnotherWindow)
    #expect(registry.canOpenAnotherWindow(from: firstWindow))
    #expect(registry.openAnotherWindow(from: firstWindow))
    let value = try #require(opened.first)
    #expect(value.projectRoot == key)
    let windowID = try #require(value.windowID)
    // Its scene resolves the key to itself, so the window keeps its id.
    #expect(AgentSettings.shared.projectRoot(for: value.projectRoot) == key)

    // The window its scene builds: the device's hosting (one per device).
    let second = deviceWindow(value.projectRoot, windowID: windowID, hosting: hosting)
    _ = claim(second)
    #expect(registry.hasWindow(value))
    #expect(registry.hasWindow(.primary(key)))
    #expect(second.isRemote)
    #expect(second.remoteHosting === hosting)
    #expect(!second.opensProject)
    let tab = try #require(second.workspace.sessions.first)
    #expect(second.workspace.sessions.count == 1)
    #expect(second.workspace.launchRoot == "/Users/them/work/app")
    #expect(tab.persistentHosting === hosting)
    // Each window uses the hosting and, with its tab, holds a lease; the
    // tabs' Creates (which fail: nothing connects) hold none once ended.
    #expect(hosting.windowUses == 2)
    let tabs = windows.compactMap { $0.repository.workspace.sessions.first }
    #expect(await eventually { tabs.allSatisfy { $0.persistentLaunchFailureReason != nil } })
    #expect(await eventually { hosting.control.activeLeaseCount == 2 })

    // Closing the new window keeps the first's use and lease.
    close(1)
    #expect(hosting.windowUses == 1)
    #expect(await eventually { hosting.control.activeLeaseCount == 1 })
    #expect(hosting.isInUse)
    #expect(registry.hasWindow(.primary(key)))
    #expect(registry.canOpenAnotherWindow(from: firstWindow))
}

/// A window of a device Cherry no longer knows (its stand-in hosting: its
/// tabs cannot start, and it keeps its saved tabs as saved) opens no other
/// window: not from New Window, the shortcut or the menu (they beep), and
/// the Omni bar does not offer it. A known device's window does.
@Test @MainActor func RemoteDeviceNewWindowIsRefusedForADeviceCherryNoLongerKnows() throws {
    let key = ProjectLocation.remote(deviceID: UUID(), path: "/Users/them/work/app").key
    let standIn = RemoteDeviceStore.unavailableHosting(
        for: key, reason: "This Mac is not among your devices any more.", instanceLock: nil
    )
    #expect(!standIn.profile.isKnownDevice)
    let registry = ProjectWindowRegistry()
    registry.bringWindowForward = { _ in }
    var opened: [ProjectWindowValue] = []
    registry.newProjectWindowOpener = { opened.append($0) }
    registry.projectWindowOpener = { _ in Issue.record("New Window opened the default project") }
    let unknown = deviceWindow(key, hosting: standIn)
    let window = testWindow()
    let chromeState = quietChromeState()
    defer {
        registry.unregister(window: window, projectRoot: key)
        unknown.closeAllSessions(intent: .windowClosed)
    }
    #expect(registry.register(
        window: window, projectRoot: key, workspace: unknown.workspace, repository: unknown,
        todoStore: nil, chromeState: chromeState
    ))
    unknown.beginRestoringSavedStateIfNeeded(chromeState: chromeState)

    #expect(!unknown.allowsAnotherWindow)
    #expect(!registry.canOpenAnotherWindow(from: window))
    #expect(!registry.openAnotherWindow(from: window))
    // Nor with no project window key, while it is the window active last.
    #expect(!registry.openAnotherWindow(from: nil))
    #expect(opened.isEmpty)
    let context = OmniBarGathering.context(
        for: OmniBarWindow(projectRoot: key, repository: unknown, workspace: unknown.workspace, chromeState: chromeState),
        settings: .shared
    )
    #expect(!context.canOpenAnotherWindow)
    var sources = OmniSources()
    sources.window = context
    #expect(!OmniProviders.commands(sources).contains { $0.id == "command:newWindow" })

    // A known device's window offers it.
    let deviceID = UUID()
    let knownKey = ProjectLocation.remote(deviceID: deviceID, path: "/Users/them/work/app").key
    let known = deviceWindow(knownKey, hosting: inertDeviceHosting("mini-\(deviceID.uuidString.prefix(8))", name: "Mini"))
    defer { known.closeAllSessions(intent: .windowClosed) }
    #expect(known.allowsAnotherWindow)
    let knownContext = OmniBarGathering.context(
        for: OmniBarWindow(projectRoot: knownKey, repository: known, workspace: known.workspace, chromeState: quietChromeState()),
        settings: .shared
    )
    #expect(knownContext.canOpenAnotherWindow)
}
