import Foundation

// The Omni bar's folders (design E, "Adding projects on any Mac"): a query
// starting with `~/` or `/` in Projects, at the root or in a Mac's scope
// lists that Mac's folders (`OmniPathQuery`, `OmniFolderRows`), and the
// git repositories found under the usual places that are not projects yet
// show as "Not added yet" (`OmniUnaddedRows`). Everything here is pure: the
// listings and repositories come in `OmniSources`, gathered by
// `OmniFolderBrowser` and `OmniRepositoryScanner` (`OmniBarFoldersLive.swift`).

/// What browsing folders is for: Add Project… adds (and opens) the folder
/// chosen, Open Folder… opens it without adding it.
enum OmniFolderIntent: Hashable {
    case add
    case openOnce
}

/// A path-like query split at its last `/`.
struct OmniPathQuery: Equatable {
    /// The folder typed, up to and with its last `/` ("~/github/", "/").
    var directory: String
    /// What follows it: the start of a folder's name ("pa").
    var segment: String

    /// Nil unless the query starts with `~/` or `/` (leading spaces aside).
    static func parse(_ query: String) -> OmniPathQuery? {
        let text = String(query.drop(while: \.isWhitespace))
        guard text.hasPrefix("~/") || text.hasPrefix("/"), let slash = text.lastIndex(of: "/") else { return nil }
        return OmniPathQuery(directory: String(text[...slash]), segment: String(text[text.index(after: slash)...]))
    }

    /// Whether the query names a folder itself ("~/github/cherry/"): the
    /// row for that folder comes first. Never the home folder or `/`.
    var namesFolder: Bool {
        segment.isEmpty && directory != "~/" && directory != "/"
    }

    /// The folder typed, without its last `/` ("~/github/cherry").
    var typedFolder: String {
        directory == "/" ? "/" : String(directory.dropLast())
    }

    /// Hidden folders are listed only for a segment that starts with ".".
    var showsHidden: Bool { segment.hasPrefix(".") }

    /// The absolute path a typed path names on a Mac whose home is `home`
    /// (nil: `~` cannot be expanded), with repeated `/` and `.` removed and
    /// `..` applied; no trailing `/` but for `/` itself.
    static func expand(_ typed: String, home: String?) -> String? {
        var path = typed
        if path == "~" || path.hasPrefix("~/") {
            guard let home = home?.nilIfEmpty, home.hasPrefix("/") else { return nil }
            path = home + "/" + path.dropFirst(1)
        }
        guard path.hasPrefix("/") else { return nil }
        var parts: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    /// The folders of a listing that match `segment`, those whose name
    /// starts with it first, then those that contain it (each
    /// alphabetical), case insensitively; hidden folders only when it
    /// starts with ".".
    static func filter(_ entries: [OmniFolderEntry], segment: String) -> [OmniFolderEntry] {
        let showsHidden = segment.hasPrefix(".")
        let visible = entries.filter { showsHidden || !$0.name.hasPrefix(".") }
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        func ordered(_ list: [OmniFolderEntry]) -> [OmniFolderEntry] {
            list.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
        guard !segment.isEmpty else { return ordered(visible) }
        var prefixed: [OmniFolderEntry] = []
        var containing: [OmniFolderEntry] = []
        for entry in visible {
            guard let range = entry.name.range(of: segment, options: options) else { continue }
            if range.lowerBound == entry.name.startIndex {
                prefixed.append(entry)
            } else {
                containing.append(entry)
            }
        }
        return ordered(prefixed) + ordered(containing)
    }
}

/// A folder in a listing.
struct OmniFolderEntry: Equatable, Hashable, Sendable {
    var name: String
    /// It has a `.git` (a repository or a worktree).
    var isRepository: Bool
}

/// What a folder holds, as listed on its Mac.
struct OmniFolderContents: Equatable, Sendable {
    /// Its absolute path there.
    var path: String
    /// It is itself a git repository.
    var isRepository: Bool
    var entries: [OmniFolderEntry]
    /// More folders than `OmniFolderListingLimits.entries` were there.
    var truncated = false
}

enum OmniFolderListingLimits {
    /// The most folders one listing returns.
    static let entries = 500
    /// The most repositories a scan returns.
    static let repositories = 500
}

/// A folder's listing as the bar knows it.
enum OmniFolderListing: Equatable, Sendable {
    /// Asked, no answer yet.
    case loading
    case listed(OmniFolderContents)
    /// No such folder there.
    case missing
    /// Its Mac is not connected: nothing is asked there until it is.
    case notConnected
    case failed(String)
}

/// A folder listing asked of a Mac: by the folder as typed ("~/github/").
struct OmniFolderRequest: Hashable, Sendable {
    var machine: ProjectSwitcherModel.Machine
    var directory: String
}

/// A git repository found under the usual places on a Mac
/// (`OmniRepositoryScanner`).
struct OmniUnaddedRepository: Equatable, Hashable, Sendable {
    var machine: ProjectSwitcherModel.Machine
    /// Its absolute path there.
    var path: String

    var name: String { (path as NSString).lastPathComponent }
    var parent: String { (path as NSString).deletingLastPathComponent }
}

extension ProjectSwitcherModel.Machine {
    /// A stable part of row ids.
    var idComponent: String {
        switch self {
        case .thisMac: "this"
        case .device(let id): id.uuidString
        }
    }
}

// MARK: - Rows

/// The rows of folder completion, and the Add Project and Open Folder rows.
enum OmniFolderRows {
    /// The Mac a path query lists in `scope`: This Mac at the root and in
    /// Projects, the Mac in a Mac's scope; nil elsewhere.
    static func machine(for scope: OmniScope?) -> ProjectSwitcherModel.Machine? {
        switch scope {
        case nil, .projects?: .thisMac
        case .mac(let machine, _)?: machine
        default: nil
        }
    }

    /// The listing a query in `scope` asks for, if it is a path query.
    static func request(scope: OmniScope?, query: String) -> OmniFolderRequest? {
        guard let machine = machine(for: scope), let path = OmniPathQuery.parse(query) else { return nil }
        return OmniFolderRequest(machine: machine, directory: path.directory)
    }

    /// "Add Project…" and "Open Folder…" (on another Mac, "… on <Mac>…")
    /// for each Mac given (every Mac whose projects can be opened when
    /// nil): ↵ enters folder completion there with "~/".
    static func browseItems(_ sources: OmniSources, on machine: ProjectSwitcherModel.Machine? = nil) -> [OmniItem] {
        let machines = sources.projects.machines.filter { info in
            if let machine { return info.machine == machine }
            return info.machine == .thisMac || info.allowsOpening
        }
        var items: [OmniItem] = []
        // This Mac's, even with no machines known (tests, early launch).
        let infos = machines.isEmpty && (machine == nil || machine == .thisMac)
            ? [(ProjectSwitcherModel.Machine.thisMac, "This Mac")]
            : machines.map { ($0.machine, $0.name) }
        for (machine, name) in infos {
            let suffix = machine == .thisMac ? "" : " on \(name)"
            let idSuffix = machine == .thisMac ? "" : ":\(machine.idComponent)"
            items.append(OmniItem(
                id: "command:addProject\(idSuffix)",
                kind: .command,
                title: "Add Project\(suffix)…",
                detail: "type a path",
                symbol: "folder.badge.plus",
                primaryLabel: "Browse",
                primary: .browseFolders(on: machine, intent: .add),
                machine: machine
            ))
            items.append(OmniItem(
                id: "command:openFolder\(idSuffix)",
                kind: .command,
                title: "Open Folder\(suffix)…",
                detail: "without adding",
                symbol: "folder",
                primaryLabel: "Browse",
                primary: .browseFolders(on: machine, intent: .openOnce),
                machine: machine
            ))
        }
        return items
    }

    /// The project already at `path` on `machine`, if any.
    static func project(at path: String, on machine: ProjectSwitcherModel.Machine, in sources: OmniSources) -> ProjectSwitcherModel.Location? {
        sources.projects.locations.first { $0.machine == machine && $0.path == path }
    }

    /// The ⌘K actions of a folder: Add to Projects, Open Once and New
    /// Terminal Here (an added one's: New Terminal Here).
    static func folderActions(path: String, on machine: ProjectSwitcherModel.Machine, isAdded: Bool) -> [OmniAction] {
        var actions: [OmniAction] = []
        if !isAdded {
            actions.append(.init(title: "Add to Projects", command: .addFolder(path: path, on: machine, open: false)))
            actions.append(.init(title: "Open Once", command: .openPath(path, on: machine)))
        }
        actions.append(.init(title: "New Terminal Here", command: .newTerminalAt(path: path, on: machine)))
        return actions
    }

    /// What ↵ does on a folder that is a project, or is to be one.
    static func open(
        path: String,
        on machine: ProjectSwitcherModel.Machine,
        project: ProjectSwitcherModel.Location?,
        intent: OmniFolderIntent
    ) -> (label: String, command: OmniCommand) {
        if let project { return ("Open", .openProject(key: project.key)) }
        switch intent {
        case .add: return ("Add & Open", .addFolder(path: path, on: machine, open: true))
        case .openOnce: return ("Open Once", .openPath(path, on: machine))
        }
    }

    /// The rows for `path` on `machine`: the folder typed itself (when the
    /// query ends in `/`), then its folders that match the segment. A
    /// Mac that is not connected gets a Connect row instead.
    static func rows(
        _ path: OmniPathQuery,
        on machine: ProjectSwitcherModel.Machine,
        sources: OmniSources,
        intent: OmniFolderIntent
    ) -> [OmniRow] {
        let request = OmniFolderRequest(machine: machine, directory: path.directory)
        switch sources.folderListings[request] {
        case .notConnected?:
            guard case .device(let id) = machine else { return [] }
            let name = sources.projects.name(of: machine)
            return [OmniRow(item: OmniItem(
                id: "folder-connect:\(id.uuidString)",
                kind: .mac,
                title: "\(name) isn't connected",
                detail: "Connect to browse its folders",
                status: .offline,
                symbol: "bolt.horizontal.circle",
                primaryLabel: "Connect",
                primary: .connectDevice(id),
                machine: machine,
                recordsUse: false
            ))]
        case .listed(let contents)?:
            return listedRows(path, contents: contents, on: machine, sources: sources, intent: intent)
        default:
            return []
        }
    }

    private static func listedRows(
        _ path: OmniPathQuery,
        contents: OmniFolderContents,
        on machine: ProjectSwitcherModel.Machine,
        sources: OmniSources,
        intent: OmniFolderIntent
    ) -> [OmniRow] {
        var rows: [OmniRow] = []
        let base = contents.path == "/" ? "" : contents.path
        if path.namesFolder {
            let project = project(at: contents.path, on: machine, in: sources)
            let open = open(path: contents.path, on: machine, project: project, intent: intent)
            rows.append(OmniRow(item: OmniItem(
                id: "folder:\(machine.idComponent):\(contents.path)",
                kind: .folder,
                title: path.typedFolder,
                detail: project != nil ? "added" : (contents.isRepository ? "git" : "this folder"),
                symbol: contents.isRepository ? "arrow.triangle.branch" : "folder",
                primaryLabel: open.label,
                primary: open.command,
                actions: folderActions(path: contents.path, on: machine, isAdded: project != nil),
                machine: machine,
                recordsUse: false
            )))
        }
        let offset = path.directory.count
        for entry in OmniPathQuery.filter(contents.entries, segment: path.segment) {
            let absolute = base + "/" + entry.name
            let project = project(at: absolute, on: machine, in: sources)
            let typed = path.directory + entry.name
            let primary: (label: String, command: OmniCommand) = entry.isRepository
                ? open(path: absolute, on: machine, project: project, intent: intent)
                : ("Browse", .enterFolder(typed + "/"))
            var matched: [Int] = []
            if !path.segment.isEmpty,
               let range = entry.name.range(of: path.segment, options: [.caseInsensitive, .diacriticInsensitive]) {
                let start = entry.name.distance(from: entry.name.startIndex, to: range.lowerBound)
                let length = entry.name.distance(from: range.lowerBound, to: range.upperBound)
                matched = Array(offset + start ..< offset + start + length)
            }
            rows.append(OmniRow(item: OmniItem(
                id: "folder:\(machine.idComponent):\(absolute)",
                kind: .folder,
                title: typed,
                detail: project != nil ? "added" : (entry.isRepository ? "git" : ""),
                symbol: entry.isRepository ? "arrow.triangle.branch" : "folder",
                primaryLabel: primary.label,
                primary: primary.command,
                actions: folderActions(path: absolute, on: machine, isAdded: project != nil),
                machine: machine,
                recordsUse: false,
                completion: typed + "/"
            ), matched: matched))
        }
        return rows
    }

    /// What the list says when it has no rows for a path query.
    static func emptyState(_ path: OmniPathQuery, on machine: ProjectSwitcherModel.Machine, sources: OmniSources) -> OmniEmptyState {
        let name = sources.projects.name(of: machine)
        switch sources.folderListings[OmniFolderRequest(machine: machine, directory: path.directory)] {
        case nil, .loading?:
            return OmniEmptyState(text: "Listing \(path.directory) on \(name)…", isLoading: true)
        case .missing?:
            return OmniEmptyState(text: "No folder \(path.typedFolder) on \(name)")
        case .failed(let message)?:
            return OmniEmptyState(text: "Could not list \(path.directory) on \(name): \(message)")
        case .notConnected?:
            return OmniEmptyState(text: "\(name) isn't connected")
        case .listed?:
            return OmniEmptyState(
                text: path.segment.isEmpty
                    ? "No folders in \(path.directory)"
                    : "Nothing in \(path.directory) starts with “\(path.segment)”"
            )
        }
    }
}

/// What the list shows when it has no rows.
struct OmniEmptyState: Equatable {
    var text = "No results"
    /// A listing is on its way (a spinner shows).
    var isLoading = false
}

/// "Not added yet": the repositories found on each Mac that are not
/// projects there, nor ones the user removed (This Mac's removed projects,
/// a device's hidden ones).
enum OmniUnaddedRows {
    /// The repositories on `machine` (every Mac when nil) that are not
    /// projects, removed or hidden, by name.
    static func repositories(_ sources: OmniSources, on machine: ProjectSwitcherModel.Machine? = nil) -> [OmniUnaddedRepository] {
        let known = Set(sources.projects.machines.map(\.machine))
        var seen = Set<OmniUnaddedRepository>()
        return sources.unaddedRepositories
            .filter { repository in
                guard machine == nil || repository.machine == machine else { return false }
                // A device this Cherry no longer knows (or one whose
                // projects cannot be opened now) lists none.
                if case .device = repository.machine {
                    guard known.contains(repository.machine),
                          sources.projects.machine(repository.machine)?.allowsOpening == true
                    else { return false }
                }
                if OmniFolderRows.project(at: repository.path, on: repository.machine, in: sources) != nil { return false }
                if sources.removedProjects[repository.machine]?.contains(repository.path) == true { return false }
                return seen.insert(repository).inserted
            }
            .sorted { lhs, rhs in
                let order = lhs.name.localizedStandardCompare(rhs.name)
                if order != .orderedSame { return order == .orderedAscending }
                return lhs.path < rhs.path
            }
    }

    /// Their rows: ↵ adds and opens; ⌘K Add to Projects, Open Once, New
    /// Terminal Here. `withQuery`: the detail says "not added · <parent>".
    static func items(
        _ sources: OmniSources,
        on machine: ProjectSwitcherModel.Machine? = nil,
        withQuery: Bool
    ) -> [OmniItem] {
        repositories(sources, on: machine).map { repository in
            let parent = ProjectSwitcherModel.displayPath(repository.parent, home: sources.homes[repository.machine])
            let place = repository.machine == .thisMac || machine != nil
                ? parent
                : "\(sources.projects.name(of: repository.machine)) · \(parent)"
            return OmniItem(
                id: "unadded:\(repository.machine.idComponent):\(repository.path)",
                kind: .project,
                title: repository.name,
                detail: withQuery ? "not added · \(place)" : place,
                symbol: "folder",
                primaryLabel: "Add & Open",
                primary: .addFolder(path: repository.path, on: repository.machine, open: true),
                actions: OmniFolderRows.folderActions(path: repository.path, on: repository.machine, isAdded: false),
                keywords: [ProjectSwitcherModel.displayPath(repository.path, home: sources.homes[repository.machine])],
                machine: repository.machine,
                recordsUse: false,
                rankBias: -1
            )
        }
    }
}
