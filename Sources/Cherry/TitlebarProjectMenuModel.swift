import CherryControl
import Foundation

/// The project picker's menu model: the window's worktrees, This Mac's
/// projects, and the user's other Macs with their projects
/// (docs/specs/remote-devices.md). Pure, built from cached state. The Omni
/// bar offers each device's items (`deviceItem`) as its Mac row's ⌘K
/// actions (`OmniProviders.macActions`) and opens projects through its
/// actions (`ProjectSwitcherActions`).
struct TitlebarProjectMenuModel: Equatable {
    struct Worktree: Equatable {
        var root: String
        var name: String
        var isActive: Bool
        var isHidden: Bool
    }

    struct Project: Equatable {
        var root: String
        var name: String
        var isSelected: Bool
    }

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
        case activateWorktree(String)
        case newWorktree
        case manageWorktrees
        case openProject(String)
        case addProject
        case editProjects
        case openDeviceProject(deviceID: UUID, path: String)
        /// "Other sessions": the Persistent Sessions sheet on that host.
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

    struct Item: Equatable {
        var title: String
        var subtitle: String?
        var isOn = false
        var isEnabled = true
        var action: Action?
        var dot: RemoteDeviceConnectionState.Dot?
        /// Shown in place of the item before it while Option is held.
        var isAlternate = false
        /// A device's item carries its id (live updates find it by it).
        var deviceID: UUID?
        var children: [Entry]?
    }

    indirect enum Entry: Equatable {
        case header(String)
        case separator
        case item(Item)
    }

    var entries: [Entry]

    /// `worktrees`: nil when the window's project has no worktree spaces.
    /// `currentProjectKey`: the window's project, checked where it is listed.
    init(
        worktrees: [Worktree]?,
        projects: [Project],
        devices: [Device],
        currentProjectKey: String?,
        canModifyDevices: Bool = true,
        now: Date = Date()
    ) {
        var entries: [Entry] = []
        if let worktrees {
            entries.append(.header("Worktrees"))
            for worktree in worktrees {
                entries.append(.item(Item(
                    title: worktree.name + (worktree.isHidden ? " — Hidden" : ""),
                    isOn: worktree.isActive,
                    action: .activateWorktree(worktree.root)
                )))
            }
            entries.append(.item(Item(title: "New Worktree...", action: .newWorktree)))
            entries.append(.item(Item(title: "Manage Worktrees...", action: .manageWorktrees)))
            entries.append(.separator)
        }
        if projects.isEmpty {
            entries.append(.item(Item(title: "No Projects", isEnabled: false)))
        } else {
            entries.append(.header("Projects"))
            for project in projects {
                entries.append(.item(Item(title: project.name, isOn: project.isSelected, action: .openProject(project.root))))
            }
        }
        entries.append(.separator)
        entries.append(.item(Item(title: "Add Project...", action: .addProject)))
        entries.append(.item(Item(title: "Edit Projects...", action: .editProjects)))
        entries.append(.separator)
        entries.append(.header("Devices"))
        for device in devices {
            entries.append(.item(Self.deviceItem(
                device, currentProjectKey: currentProjectKey, canModify: canModifyDevices, now: now
            )))
        }
        // Only the copy of the app that keeps the devices changes them.
        entries.append(.item(Item(title: "Add Mac…", isEnabled: canModifyDevices, action: .addMac)))
        self.entries = entries
    }

    static func deviceItem(_ entry: Device, currentProjectKey: String?, canModify: Bool = true, now: Date) -> Item {
        let device = entry.device
        let id = device.id
        let (projects, otherCount) = RemoteDeviceDiscovery.projects(
            sessions: entry.sessions, added: device.addedProjects, hidden: device.hiddenProjects
        )
        let canOpen = entry.state.allowsOpening
        var children: [Entry] = []
        if projects.isEmpty {
            children.append(.item(Item(title: "No Projects", isEnabled: false)))
        }
        for project in projects {
            let key = device.projectKey(path: project.path)
            let count = project.sessionCount
            children.append(.item(Item(
                title: project.name,
                subtitle: count == 0 ? project.path : "\(count == 1 ? "1 session" : "\(count) sessions") · \(project.path)",
                isOn: key == currentProjectKey,
                isEnabled: canOpen,
                action: .openDeviceProject(deviceID: id, path: project.path)
            )))
            // Option: leave it out of the list (its sessions keep running).
            children.append(.item(Item(
                title: "Hide \(project.name)",
                subtitle: project.path,
                isEnabled: canModify,
                action: .hideDeviceProject(deviceID: id, path: project.path),
                isAlternate: true
            )))
        }
        if otherCount > 0 {
            children.append(.item(Item(
                title: "Other sessions",
                subtitle: otherCount == 1 ? "1 session" : "\(otherCount) sessions",
                isEnabled: canOpen,
                action: .openDeviceSessions(id)
            )))
        }
        children.append(.separator)
        children.append(.item(Item(
            title: "Open Home Folder",
            subtitle: device.homeDirectory,
            isEnabled: canOpen && device.homeDirectory != nil,
            action: .openDeviceHome(id)
        )))
        children.append(.item(Item(title: "Add Project on \(device.name)…", isEnabled: canOpen && canModify, action: .addDeviceProject(id))))
        children.append(.separator)
        children.append(.item(Item(title: entry.state.detail, isEnabled: false, dot: entry.state.dot)))
        if entry.state.offersReconnect {
            children.append(.item(Item(title: "Reconnect", action: .reconnectDevice(id))))
        }
        if entry.state.offersTrustNewIdentity {
            children.append(.item(Item(title: "Trust New Identity…", isEnabled: canModify, action: .trustDeviceIdentity(id))))
        }
        if entry.offersHostUpdate {
            children.append(.item(Item(title: entry.hostUpdateTitle, isEnabled: canModify, action: .updateDeviceHost(id))))
        }
        children.append(.item(Item(title: "Persistent Sessions on \(device.name)…", action: .openDeviceSessions(id))))
        children.append(.item(Item(title: "Set Up Cherry MCP on \(device.name)…", isEnabled: canOpen, action: .setUpDeviceMCP(id))))
        children.append(.separator)
        children.append(.item(Item(title: "Rename…", isEnabled: canModify, action: .renameDevice(id))))
        children.append(.item(Item(title: "Remove…", isEnabled: canModify, action: .removeDevice(id))))
        let isCurrent = currentProjectKey.map { ProjectLocation(key: $0).deviceID == id } ?? false
        return Item(
            title: device.name,
            subtitle: entry.state.subtitle(now: now),
            isOn: isCurrent,
            dot: entry.state.dot,
            deviceID: id,
            children: children
        )
    }

    /// A plain-text rendering, for tests: one line per entry, children
    /// indented; `[x]` checked, `(off)` disabled, `●color` a status dot.
    var snapshot: String {
        Self.snapshot(entries, depth: 0).joined(separator: "\n")
    }

    private static func snapshot(_ entries: [Entry], depth: Int) -> [String] {
        let indent = String(repeating: "  ", count: depth)
        var lines: [String] = []
        for entry in entries {
            switch entry {
            case .header(let title):
                lines.append("\(indent)## \(title)")
            case .separator:
                lines.append("\(indent)---")
            case .item(let item):
                var line = indent
                if item.isAlternate { line += "⌥ " }
                if item.isOn { line += "[x] " }
                if let dot = item.dot { line += "●\(dot.rawValue) " }
                line += item.title
                if let subtitle = item.subtitle { line += " — \(subtitle)" }
                if !item.isEnabled { line += " (off)" }
                lines.append(line)
                if let children = item.children {
                    lines += snapshot(children, depth: depth + 1)
                }
            }
        }
        return lines
    }

    /// The entry of each device's item, by device id.
    var deviceItems: [UUID: Item] {
        var items: [UUID: Item] = [:]
        for case .item(let item) in entries {
            if let id = item.deviceID { items[id] = item }
        }
        return items
    }
}
