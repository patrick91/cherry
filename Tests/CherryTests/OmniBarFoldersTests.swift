import AppKit
import CherryControl
import Foundation
import Testing
@testable import Cherry

// The Omni bar's folders (design E): path queries and their completion,
// Add Project and Open Folder as rows, "Not added yet", the listing and
// scanning scripts another Mac runs (run here with sh against a temp
// folder, to show no folder name or query runs anything), and the folder
// browser and repository scanner asking only a connected device. No host,
// ssh, window or real store is touched.

private let studioID = UUID(uuidString: "00000000-0000-0000-0000-00000000D00D")!
private let goneID = UUID(uuidString: "00000000-0000-0000-0000-00000000DEAD")!

private func location(_ path: String, on machine: ProjectSwitcherModel.Machine = .thisMac) -> ProjectSwitcherModel.Location {
    let key = machine == .thisMac ? path : ProjectLocation.remote(deviceID: studioID, path: path).key
    return .init(
        machine: machine, key: key, name: (path as NSString).lastPathComponent, path: path,
        displayPath: ProjectSwitcherModel.displayPath(path, home: "/Users/me")
    )
}

private func sources() -> OmniSources {
    var sources = OmniSources()
    sources.projects = ProjectSwitcherModel(
        machines: [
            .init(machine: .thisMac, name: "This Mac", status: "", dot: .green, detail: ""),
            .init(machine: .device(studioID), name: "patstudio", status: "", dot: .green, detail: ""),
        ],
        locations: [location("/Users/me/code/cherry"), location("/Users/me/code/rignore", on: .device(studioID))]
    )
    sources.homes = [.thisMac: "/Users/me", .device(studioID): "/Users/me"]
    sources.window = OmniWindowContext(hasWorkspace: true, supportsWorktrees: true)
    return sources
}

private let codeListing = OmniFolderContents(
    path: "/Users/me/code",
    isRepository: false,
    entries: [
        .init(name: "notes", isRepository: false),
        .init(name: "newrepo", isRepository: true),
        .init(name: "my-cherry-fork", isRepository: true),
        .init(name: ".hidden", isRepository: false),
        .init(name: "cherry", isRepository: true),
    ]
)

@MainActor
private final class FolderRecorder {
    var run: [OmniCommand] = []
    var requests: [OmniFolderRequest] = []

    func controller(_ sources: OmniSources) -> OmniBarController {
        let controller = OmniBarController(sources: sources, run: { [weak self] in self?.run.append($0) })
        controller.requestFolderListing = { [weak self] in self?.requests.append($0) }
        return controller
    }
}

@MainActor
private func select(_ title: String, in controller: OmniBarController) throws {
    controller.select(try #require(controller.rows.firstIndex { $0.item.title == title }))
}

// MARK: - Path queries

@Test func omniPathQueriesSplitAtTheirLastSlashAndExpandHome() {
    #expect(OmniPathQuery.parse("~/gi") == OmniPathQuery(directory: "~/", segment: "gi"))
    #expect(OmniPathQuery.parse("  ~/github/pat") == OmniPathQuery(directory: "~/github/", segment: "pat"))
    #expect(OmniPathQuery.parse("/") == OmniPathQuery(directory: "/", segment: ""))
    #expect(OmniPathQuery.parse("/Users/me/code/") == OmniPathQuery(directory: "/Users/me/code/", segment: ""))
    #expect(OmniPathQuery.parse("~") == nil)
    #expect(OmniPathQuery.parse("gi") == nil)
    #expect(OmniPathQuery.parse("a/b") == nil)
    // The folder typed itself: not home, not "/".
    #expect(OmniPathQuery.parse("~/github/")?.namesFolder == true)
    #expect(OmniPathQuery.parse("~/github/")?.typedFolder == "~/github")
    #expect(OmniPathQuery.parse("~/")?.namesFolder == false)
    #expect(OmniPathQuery.parse("/")?.namesFolder == false)
    #expect(OmniPathQuery.parse("~/github/c")?.namesFolder == false)

    #expect(OmniPathQuery.expand("~/github/", home: "/Users/me") == "/Users/me/github")
    #expect(OmniPathQuery.expand("~/", home: "/Users/me") == "/Users/me")
    #expect(OmniPathQuery.expand("~", home: "/Users/me/") == "/Users/me")
    #expect(OmniPathQuery.expand("/a//b/./c/../", home: nil) == "/a/b")
    #expect(OmniPathQuery.expand("/", home: nil) == "/")
    // A home not known: "~" cannot be expanded.
    #expect(OmniPathQuery.expand("~/x", home: nil) == nil)
    #expect(OmniPathQuery.expand("x/y", home: "/Users/me") == nil)
}

@Test func omniFolderFilterPutsPrefixesFirstThenContainsAndHidesDotFolders() {
    let entries = ["Cherry", "my-cherry-fork", "achy", ".cherry-cache", "zeta", "cherries", ".config"].map {
        OmniFolderEntry(name: $0, isRepository: false)
    }
    #expect(OmniPathQuery.filter(entries, segment: "cher").map(\.name) == ["cherries", "Cherry", "my-cherry-fork"])
    #expect(OmniPathQuery.filter(entries, segment: "").map(\.name) == ["achy", "cherries", "Cherry", "my-cherry-fork", "zeta"])
    // Hidden folders only for a segment that starts with ".".
    #expect(OmniPathQuery.filter(entries, segment: ".").map(\.name) == [".cherry-cache", ".config"])
    #expect(OmniPathQuery.filter(entries, segment: ".c").map(\.name) == [".cherry-cache", ".config"])
    #expect(OmniPathQuery.filter(entries, segment: "xyz").isEmpty)
}

@Test @MainActor func omniPathQueriesListFoldersWithRepositoriesAndAddedOnesMarked() throws {
    let recorder = FolderRecorder()
    var listed = sources()
    listed.folderListings[OmniFolderRequest(machine: .thisMac, directory: "~/code/")] = .listed(codeListing)
    let controller = recorder.controller(listed)
    controller.open(at: .projects)
    controller.setQuery("~/code/")
    #expect(recorder.requests == [OmniFolderRequest(machine: .thisMac, directory: "~/code/")])
    #expect(controller.hint == "Folders on This Mac · ⇥ completes")
    // The folder typed first, then its folders, alphabetical, hidden ones not.
    #expect(controller.rows.map(\.item.title) == [
        "~/code", "~/code/cherry", "~/code/my-cherry-fork", "~/code/newrepo", "~/code/notes",
    ])
    #expect(controller.rows.map(\.item.detail) == ["this folder", "added", "git", "git", ""])
    #expect(controller.rows.map(\.item.symbol) == ["folder", "arrow.triangle.branch", "arrow.triangle.branch", "arrow.triangle.branch", "folder"])
    #expect(controller.rows[0].item.primaryLabel == "Add & Open")
    #expect(controller.rows[0].item.primary == .addFolder(path: "/Users/me/code", on: .thisMac, open: true))

    // The segment filters: prefix first, then contains, the match in bold.
    controller.setQuery("~/code/cher")
    #expect(controller.rows.map(\.item.title) == ["~/code/cherry", "~/code/my-cherry-fork"])
    #expect(controller.rows[0].matched == [7, 8, 9, 10])
    #expect(controller.rows[1].matched == [10, 11, 12, 13])
    // ↵ on an added repository opens it.
    controller.activate()
    #expect(recorder.run == [.openProject(key: "/Users/me/code/cherry")])
    // ⇥ completes the selected folder with "/", and lists it.
    #expect(controller.drillIntoSelection())
    #expect(controller.query == "~/code/cherry/")
    #expect(recorder.requests.last == OmniFolderRequest(machine: .thisMac, directory: "~/code/cherry/"))
    // Its listing is on its way.
    #expect(controller.rows.isEmpty)
    #expect(controller.emptyState == OmniEmptyState(text: "Listing ~/code/cherry/ on This Mac…", isLoading: true))

    // A repository not added: ↵ adds and opens it; ⌘K adds, opens once or
    // starts a terminal there.
    controller.setQuery("~/code/new")
    #expect(controller.primaryLabel == "Add & Open")
    #expect(controller.toggleActions())
    #expect(controller.selectedActions.map(\.title) == ["Add to Projects", "Open Once", "New Terminal Here"])
    #expect(controller.selectedActions.map(\.command) == [
        .addFolder(path: "/Users/me/code/newrepo", on: .thisMac, open: false),
        .openPath("/Users/me/code/newrepo", on: .thisMac),
        .newTerminalAt(path: "/Users/me/code/newrepo", on: .thisMac),
    ])
    controller.toggleActions()
    controller.activate()
    #expect(recorder.run.last == .addFolder(path: "/Users/me/code/newrepo", on: .thisMac, open: true))

    // ↵ on a plain folder enters it (nothing runs).
    let ran = recorder.run.count
    controller.setQuery("~/code/no")
    #expect(controller.primaryLabel == "Browse")
    controller.activate()
    #expect(controller.query == "~/code/notes/")
    #expect(recorder.run.count == ran)

    // Hidden folders show for a segment that starts with ".".
    controller.setQuery("~/code/.")
    #expect(controller.rows.map(\.item.title) == ["~/code/.hidden"])
    controller.setQuery("~/code/zzz")
    #expect(controller.emptyState.text == "Nothing in ~/code/ starts with “zzz”")
}

@Test @MainActor func omniAddProjectAndOpenFolderAreRowsThatEnterFolderCompletion() throws {
    let recorder = FolderRecorder()
    var listed = sources()
    listed.folderListings[OmniFolderRequest(machine: .thisMac, directory: "~/code/")] = .listed(codeListing)
    listed.unaddedRepositories = [OmniUnaddedRepository(machine: .thisMac, path: "/Users/me/github/alpacas-and-ducks")]
    let controller = recorder.controller(listed)
    // At the root, "add" finds Add Project on every Mac, and never
    // "alpacas-and-ducks" through scattered letters.
    controller.setQuery("add")
    let titles = controller.rows.map(\.item.title)
    #expect(titles.contains("Add Project…") && titles.contains("Add Project on patstudio…"))
    #expect(!titles.contains("alpacas-and-ducks"))
    // ↵ enters Projects with "~/", listing This Mac's home.
    try select("Add Project…", in: controller)
    controller.activate()
    #expect(controller.stack == [.projects] && controller.query == "~/")
    #expect(recorder.requests.last == OmniFolderRequest(machine: .thisMac, directory: "~/"))
    #expect(recorder.run.isEmpty)

    // Open Folder…: a repository's ↵ opens it once, without adding it.
    controller.open(at: .projects)
    controller.setQuery("open folder")
    try select("Open Folder…", in: controller)
    controller.activate()
    #expect(controller.folderIntent == .openOnce && controller.query == "~/")
    controller.setQuery("~/code/newrepo")
    #expect(controller.primaryLabel == "Open Once")
    controller.activate()
    #expect(recorder.run.last == .openPath("/Users/me/code/newrepo", on: .thisMac))
    // A new scope adds again.
    controller.open(at: .projects)
    #expect(controller.folderIntent == .add)

    // Another Mac's row enters that Mac's scope.
    controller.open(at: nil)
    controller.setQuery("add project on")
    try select("Add Project on patstudio…", in: controller)
    controller.activate()
    #expect(controller.stack == [.macs, .mac(.device(studioID), name: "patstudio")])
    #expect(controller.query == "~/")
    #expect(recorder.requests.last == OmniFolderRequest(machine: .device(studioID), directory: "~/"))

    // In Projects without a query, This Mac's two rows close the list; the
    // Mac's ⌘K Add Project… browses too.
    controller.open(at: .projects)
    #expect(controller.sections.last?.rows.map(\.item.title) == ["Add Project…", "Open Folder…"])
    let thisMac = try #require(OmniProviders.macs(listed).first)
    #expect(thisMac.actions.first { $0.title == "Add Project…" }?.command == .browseFolders(on: .thisMac, intent: .add))
    #expect(thisMac.actions.first { $0.title == "Open Folder…" }?.command == .browseFolders(on: .thisMac, intent: .openOnce))
    // In the Commands scope, Add Project… keeps its old id (its frecency).
    #expect(OmniProviders.commands(listed).contains { $0.id == "command:addProject" && $0.title == "Add Project…" })
}

@Test @MainActor func omniAMacThatIsNotConnectedOffersConnectInsteadOfItsFolders() throws {
    let recorder = FolderRecorder()
    var offline = sources()
    offline.folderListings[OmniFolderRequest(machine: .device(studioID), directory: "~/")] = .notConnected
    let controller = recorder.controller(offline)
    controller.open(at: .mac(.device(studioID), name: "patstudio"))
    controller.setQuery("~/")
    #expect(recorder.requests == [OmniFolderRequest(machine: .device(studioID), directory: "~/")])
    #expect(controller.hint == "Folders on patstudio · ⇥ completes")
    #expect(controller.rows.map(\.item.title) == ["patstudio isn't connected"])
    #expect(controller.primaryLabel == "Connect")
    controller.activate()
    #expect(recorder.run == [.connectDevice(studioID)])
    // Missing and failed listings say so.
    var missing = sources()
    missing.folderListings[OmniFolderRequest(machine: .device(studioID), directory: "~/nope/")] = .missing
    let other = recorder.controller(missing)
    other.open(at: .mac(.device(studioID), name: "patstudio"))
    other.setQuery("~/nope/")
    #expect(other.rows.isEmpty)
    #expect(other.emptyState.text == "No folder ~/nope on patstudio")
    #expect(!other.emptyState.isLoading)
}

// MARK: - Not added yet

@Test @MainActor func omniNotAddedYetLeavesOutProjectsRemovedHiddenAndUnknownMacs() throws {
    var found = sources()
    let offlineID = UUID()
    found.projects.machines.append(.init(
        machine: .device(offlineID), name: "offline", status: "", dot: .gray, detail: "", isReachable: false, allowsOpening: false
    ))
    found.unaddedRepositories = [
        OmniUnaddedRepository(machine: .thisMac, path: "/Users/me/code/cherry"), // a project
        OmniUnaddedRepository(machine: .thisMac, path: "/Users/me/github/pat/newrepo"),
        OmniUnaddedRepository(machine: .thisMac, path: "/Users/me/github/pat/removed"), // removed
        OmniUnaddedRepository(machine: .device(studioID), path: "/Users/me/code/rignore"), // a project there
        OmniUnaddedRepository(machine: .device(studioID), path: "/Users/me/code/hidden-one"), // hidden there
        OmniUnaddedRepository(machine: .device(studioID), path: "/Users/me/code/duck-dash"),
        OmniUnaddedRepository(machine: .device(studioID), path: "/Users/me/code/cherry"), // not a project there
        OmniUnaddedRepository(machine: .device(goneID), path: "/Users/me/code/gone"), // a Mac no longer known
        OmniUnaddedRepository(machine: .device(offlineID), path: "/Users/me/code/elsewhere"), // cannot open there
    ]
    found.removedProjects = [.thisMac: ["/Users/me/github/pat/removed"], .device(studioID): ["/Users/me/code/hidden-one"]]
    #expect(OmniUnaddedRows.repositories(found).map(\.path) == [
        "/Users/me/code/cherry", "/Users/me/code/duck-dash", "/Users/me/github/pat/newrepo",
    ])

    let controller = OmniBarController(sources: found)
    controller.open(at: .projects)
    let section = try #require(controller.sections.first { $0.title == "Not added yet" })
    #expect(section.rows.map(\.item.title) == ["cherry", "duck-dash", "newrepo"])
    #expect(section.rows.map(\.item.detail) == ["patstudio · ~/code", "patstudio · ~/code", "~/github/pat"])
    let duck = section.rows[1].item
    #expect(duck.primaryLabel == "Add & Open")
    #expect(duck.primary == .addFolder(path: "/Users/me/code/duck-dash", on: .device(studioID), open: true))
    #expect(duck.actions.map(\.title) == ["Add to Projects", "Open Once", "New Terminal Here"])
    #expect(duck.actions.map(\.command) == [
        .addFolder(path: "/Users/me/code/duck-dash", on: .device(studioID), open: false),
        .openPath("/Users/me/code/duck-dash", on: .device(studioID)),
        .newTerminalAt(path: "/Users/me/code/duck-dash", on: .device(studioID)),
    ])

    // With a query they are results, saying so; a project of the same
    // name comes first.
    controller.setQuery("cherry")
    #expect(controller.rows.map(\.item.title) == ["cherry", "cherry"])
    #expect(controller.rows.map(\.item.detail) == ["", "not added · patstudio · ~/code"])
    // In a Mac's scope: that Mac's only, without its name.
    controller.open(at: .mac(.device(studioID), name: "patstudio"))
    #expect(controller.sections.first { $0.title == "Not added yet" }?.rows.map(\.item.detail) == ["~/code", "~/code"])
    controller.setQuery("duck")
    #expect(controller.rows.map(\.item.detail) == ["not added · ~/code"])
}

// MARK: - The scripts another Mac runs

/// A folder with names that would run something if a shell read them.
private let hostileNames = ["it's", "$(touch pwned-sub)", "`touch pwned-tick`", "new\nline", "sp ace", "\"quoted\"", "-n", "a;touch pwned-semi"]

private func runLocally(_ script: String, home: URL, in directory: URL) throws -> RemoteDeviceShell.DataOutput {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-s"]
    process.currentDirectoryURL = directory
    process.environment = ["HOME": home.path, "PATH": "/usr/bin:/bin"]
    let input = Pipe(), output = Pipe()
    process.standardInput = input
    process.standardOutput = output
    process.standardError = FileHandle.nullDevice
    try process.run()
    input.fileHandleForWriting.write(Data(script.utf8))
    try input.fileHandleForWriting.close()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return RemoteDeviceShell.DataOutput(status: process.terminationStatus, standardOutput: data, standardError: "")
}

private func pwnedFiles(under root: URL) -> [String] {
    let enumerator = FileManager.default.enumerator(atPath: root.path)
    var found: [String] = []
    while let path = enumerator?.nextObject() as? String {
        if (path as NSString).lastPathComponent.hasPrefix("pwned") { found.append(path) }
    }
    return found
}

@Test func omniRemoteListingScriptRunsNothingFromFolderNamesOrTheQuery() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("omni-folders-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    // The home folder's own name, and the folder asked for, are hostile too.
    let home = root.appendingPathComponent("home $(touch pwned-home) 'q'", isDirectory: true)
    let asked = home.appendingPathComponent("it's $(touch pwned-dir) `x`\nnl", isDirectory: true)
    let cwd = root.appendingPathComponent("cwd", isDirectory: true)
    for url in [asked, cwd] { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
    for name in hostileNames {
        try FileManager.default.createDirectory(at: asked.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    try FileManager.default.createDirectory(at: asked.appendingPathComponent("repo").appendingPathComponent(".git"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: asked.appendingPathComponent(".dot"), withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: asked.appendingPathComponent("a-file").path, contents: Data())
    // The folder asked for is itself a repository (a worktree's .git file).
    FileManager.default.createFile(atPath: asked.appendingPathComponent(".git").path, contents: Data("gitdir: x".utf8))

    let script = OmniRemoteFolders.listScript(directory: "~/" + asked.lastPathComponent + "/")
    // The folder asked for never appears in the script as text.
    #expect(!script.contains("pwned"))
    #expect(!script.contains("it's"))
    let listing = OmniRemoteFolders.parseListing(try runLocally(script, home: home, in: cwd))
    guard case .listed(let contents) = listing else {
        Issue.record("not listed: \(listing)")
        return
    }
    #expect(contents.path == asked.path)
    #expect(contents.isRepository)
    #expect(Set(contents.entries.map(\.name)) == Set(hostileNames + ["repo", ".dot"]))
    #expect(contents.entries.first { $0.name == "repo" }?.isRepository == true)
    #expect(contents.entries.filter(\.isRepository).map(\.name) == ["repo"])
    #expect(pwnedFiles(under: root).isEmpty)

    // An absolute path, and one no folder is at.
    let absolute = OmniRemoteFolders.parseListing(try runLocally(OmniRemoteFolders.listScript(directory: asked.path + "/"), home: home, in: cwd))
    #expect(absolute == listing)
    let missing = OmniRemoteFolders.parseListing(try runLocally(
        OmniRemoteFolders.listScript(directory: "~/nope'; touch pwned-query; '/"), home: home, in: cwd
    ))
    #expect(missing == .missing)
    #expect(pwnedFiles(under: root).isEmpty)

    // Capped, and said so.
    let capped = OmniRemoteFolders.parseListing(try runLocally(OmniRemoteFolders.listScript(directory: asked.path, limit: 3), home: home, in: cwd))
    guard case .listed(let few) = capped else {
        Issue.record("not listed: \(capped)")
        return
    }
    #expect(few.entries.count == 3 && few.truncated)

    // No marker (ssh failed): a failure, not an empty folder.
    let failed = OmniRemoteFolders.parseListing(.init(status: 255, standardOutput: Data(), standardError: "ssh: connect to host x port 22: Connection refused"))
    if case .failed = failed {} else { Issue.record("expected a failure, got \(failed)") }
    // Cut short: a failure too.
    var cut = Data((OmniRemoteFolders.listMarker + "\n").utf8)
    cut.append(Data("P/Users/me\0Dcode\0".utf8))
    if case .failed = OmniRemoteFolders.parseListing(.init(status: 0, standardOutput: cut, standardError: "")) {} else {
        Issue.record("a listing without its end was taken")
    }
}

@Test func omniRemoteScanScriptFindsRepositoriesUnderTheUsualPlaces() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("omni-scan-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let home = root.appendingPathComponent("home", isDirectory: true)
    let repositories = [
        "github/patrick91/cherry", "github/org/$(touch pwned-scan)", "github/solo", "code/app", "src/new\nline",
        "Developer/swift", "projects/p",
    ]
    for path in repositories {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(path).appendingPathComponent(".git"), withIntermediateDirectories: true)
    }
    // Not repositories, or too deep, or elsewhere.
    for path in ["github/patrick91/notes", "code/app/nested/deep", "Documents/talk"] {
        try FileManager.default.createDirectory(at: home.appendingPathComponent(path), withIntermediateDirectories: true)
    }
    try FileManager.default.createDirectory(at: home.appendingPathComponent("Documents/talk/.git"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: home.appendingPathComponent("code/app/nested/deep/.git"), withIntermediateDirectories: true)

    let found = try #require(OmniRemoteFolders.parseScan(try runLocally(OmniRemoteFolders.scanScript(), home: home, in: root)))
    let expected = Set(repositories.map { home.path + "/" + $0 })
    #expect(Set(found) == expected)
    #expect(pwnedFiles(under: root).isEmpty)
    // This Mac's scan finds the same.
    #expect(Set(OmniLocalFolders.scan(home: home.path)) == expected)
    // ssh failed: nothing known (what was found before stays).
    #expect(OmniRemoteFolders.parseScan(.init(status: 255, standardOutput: Data(), standardError: "")) == nil)
}

@Test func omniLocalListingMarksRepositoriesAndKeepsHiddenFoldersForTheFilter() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("omni-local-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for path in ["repo/.git", "plain", ".hidden"] {
        try FileManager.default.createDirectory(at: root.appendingPathComponent(path), withIntermediateDirectories: true)
    }
    FileManager.default.createFile(atPath: root.appendingPathComponent("file").path, contents: Data())
    guard case .listed(let contents) = OmniLocalFolders.list(root.path) else {
        Issue.record("not listed")
        return
    }
    #expect(contents.path == root.path && !contents.isRepository)
    #expect(contents.entries == [.init(name: "plain", isRepository: false), .init(name: "repo", isRepository: true), .init(name: ".hidden", isRepository: false)])
    #expect(OmniLocalFolders.list(root.appendingPathComponent("nope").path) == .missing)
    #expect(OmniLocalFolders.list(root.appendingPathComponent("file").path) == .missing)
}

// MARK: - Asking only connected Macs

@MainActor
private final class Counter {
    var local: [String] = []
    var remote: [(UUID, String)] = []
    var scans: [UUID] = []
    var connected = false
    var localScans = 0
    var canWrite = false
    var now = Date(timeIntervalSince1970: 1_800_000_000)
}

@MainActor
private func waitUntil(_ condition: @MainActor () -> Bool) async {
    for _ in 0 ..< 200 where !condition() {
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

@Test @MainActor func omniFolderBrowserAsksADeviceOnlyWhileItIsConnectedAndKeepsListings() async {
    let counter = Counter()
    let listing = OmniFolderListing.listed(OmniFolderContents(path: "/Users/me", isRepository: false, entries: []))
    let browser = OmniFolderBrowser(
        listLocal: { path in
            await MainActor.run { counter.local.append(path) }
            return listing
        },
        listRemote: { id, directory in
            counter.remote.append((id, directory))
            return listing
        },
        isConnected: { _ in counter.connected },
        localHome: { "/Users/me" },
        now: { counter.now }
    )
    let device = OmniFolderRequest(machine: .device(studioID), directory: "~/")
    browser.request(device)
    #expect(browser.listings[device] == .notConnected)
    browser.retryDisconnected()
    await waitUntil { false }
    #expect(counter.remote.isEmpty)

    // Connected now: asked once, and kept for a while.
    counter.connected = true
    browser.retryDisconnected()
    #expect(browser.listings[device] == .loading)
    await waitUntil { browser.listings[device] == listing }
    #expect(counter.remote.count == 1 && counter.remote.first?.1 == "~/")
    browser.request(device)
    counter.now.addTimeInterval(OmniFolderBrowser.remoteLifetime - 1)
    browser.request(device)
    #expect(counter.remote.count == 1)
    counter.now.addTimeInterval(2)
    browser.request(device)
    await waitUntil { counter.remote.count == 2 }
    #expect(counter.remote.count == 2)

    // This Mac: expanded, and kept a few seconds.
    let local = OmniFolderRequest(machine: .thisMac, directory: "~/code/")
    browser.request(local)
    browser.request(local)
    await waitUntil { browser.listings[local] == listing }
    #expect(counter.local == ["/Users/me/code"])
    counter.now.addTimeInterval(OmniFolderBrowser.localLifetime + 1)
    browser.request(local)
    await waitUntil { counter.local.count == 2 }
    #expect(counter.local.count == 2)
}

@Test @MainActor func omniRepositoryScannerScansOnlyConnectedDevicesAndKeepsWhatTheyHad() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("omni-scanner-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let cacheURL = directory.appendingPathComponent(OmniRepositoryScanner.fileName)
    let counter = Counter()
    let device = RemoteDevice(id: studioID, name: "patstudio", sshDestination: "patstudio")
    func scanner() -> OmniRepositoryScanner {
        OmniRepositoryScanner(
            cacheURL: cacheURL,
            canWrite: { counter.canWrite },
            devices: { [device] },
            isConnected: { _ in counter.connected },
            scanLocal: {
                await MainActor.run { counter.localScans += 1 }
                return ["/Users/me/code/app"]
            },
            scanRemote: { device in
                counter.scans.append(device.id)
                return ["/Users/me/code/duck-dash"]
            },
            now: { counter.now }
        )
    }
    let first = scanner()
    first.scanIfDue()
    await waitUntil { !first.repositories.isEmpty }
    // Not connected: This Mac only; the device is never asked.
    #expect(first.repositories == [OmniUnaddedRepository(machine: .thisMac, path: "/Users/me/code/app")])
    #expect(counter.scans.isEmpty)
    // Again within the interval: not scanned again.
    first.scanIfDue()
    await waitUntil { false }
    #expect(counter.localScans == 1)

    counter.connected = true
    first.scanIfDue()
    await waitUntil { first.repositories.count == 2 }
    #expect(counter.scans == [studioID])
    #expect(first.repositories.last == OmniUnaddedRepository(machine: .device(studioID), path: "/Users/me/code/duck-dash"))
    // Not the instance-lock holder: nothing written.
    #expect(!FileManager.default.fileExists(atPath: cacheURL.path))
    first.scanIfDue()
    await waitUntil { false }
    #expect(counter.scans.count == 1)

    // Ten minutes later, as the holder: scanned and written.
    counter.canWrite = true
    counter.now.addTimeInterval(OmniRepositoryScanner.remoteInterval)
    first.scanIfDue()
    await waitUntil { FileManager.default.fileExists(atPath: cacheURL.path) }
    #expect(counter.scans.count == 2)

    // The next launch shows it at once, without asking the device.
    counter.connected = false
    let next = scanner()
    #expect(next.repositories == [OmniUnaddedRepository(machine: .device(studioID), path: "/Users/me/code/duck-dash")])
    #expect(counter.scans.count == 2)
}

// MARK: - Running the rows

@Test @MainActor func omniAddingAFolderOnThisMacAddsItAndRemovingItKeepsItOutOfNotAdded() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("omni-add-\(UUID().uuidString)", isDirectory: true)
    let folder = root.appendingPathComponent("newrepo", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let suite = "cherry-omni-folders-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let settings = AgentSettings(defaults: defaults)
    let chrome = ProjectWindowChromeState()
    var opened: [String] = []
    let performer = OmniBarPerformer(
        window: OmniBarWindow(
            projectRoot: root.path, repository: RepositoryWorkspace(projectRoot: root.path),
            workspace: TerminalWorkspace(projectRoot: root.path, createInitialSession: false), chromeState: chrome
        ),
        settings: settings,
        registry: ProjectWindowRegistry(),
        backgroundSessionsModel: { preconditionFailure("not asked in this test") },
        switcher: ProjectSwitcherActions(settings: settings, chromeState: chrome, openProject: { opened.append($0.root) }, openSettings: {}),
        editorDiscovery: ExternalEditorDiscovery(appURLResolver: { _ in nil }, iconProvider: { _ in NSImage() }),
        projects: { ProjectSwitcherModel(machines: [], locations: []) },
        openSettings: {},
        toggleAppearance: {}
    )
    let path = folder.path
    performer.perform(.addFolder(path: path, on: .thisMac, open: false))
    let project = try #require(settings.projects.first)
    #expect(opened.isEmpty)
    #expect(chrome.toasts.current?.title == "\(project.name) was added to Projects")
    settings.removeProject(project)
    #expect(settings.removedProjectRoots == [project.root])
    // Remembered: another copy of the settings reads it.
    #expect(AgentSettings(defaults: defaults).removedProjectRoots == [project.root])
    // Added and opened again: no longer removed.
    performer.perform(.addFolder(path: path, on: .thisMac, open: true))
    #expect(settings.removedProjectRoots.isEmpty)
    #expect(opened == [project.root])
    // A folder that is not there: said so, nothing added.
    performer.perform(.addFolder(path: root.appendingPathComponent("gone").path, on: .thisMac, open: true))
    #expect(settings.projects.count == 1)
    #expect(chrome.toasts.current?.title.hasPrefix("There is no folder at") == true)
}
