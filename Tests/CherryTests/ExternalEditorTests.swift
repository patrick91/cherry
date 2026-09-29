import AppKit
import Testing

@testable import Cherry

private func catalogEditor(_ id: String) -> KnownEditor {
    ExternalEditorCatalog.all.first { $0.id == id }!
}

private func installed(_ id: String, appPath: String? = nil) -> InstalledEditor {
    let editor = catalogEditor(id)
    return InstalledEditor(
        editor: editor,
        bundleIdentifier: editor.bundleIdentifiers[0],
        appURL: URL(fileURLWithPath: appPath ?? "/Applications/\(editor.displayName).app")
    )
}

@MainActor
private func makeDiscovery(resolving urlsByBundleID: [String: URL]) -> ExternalEditorDiscovery {
    ExternalEditorDiscovery(
        appURLResolver: { urlsByBundleID[$0] },
        iconProvider: { _ in NSImage() }
    )
}

@Test func externalEditorCatalogHasUniqueIDsAndBundleIDs() {
    let ids = ExternalEditorCatalog.all.map(\.id)
    #expect(Set(ids).count == ids.count)

    let bundleIDs = ExternalEditorCatalog.all.flatMap(\.bundleIdentifiers)
    #expect(Set(bundleIDs).count == bundleIDs.count)
}

@MainActor
@Test func externalEditorDiscoveryPreservesCatalogOrder() {
    let discovery = makeDiscovery(resolving: [
        "com.apple.dt.Xcode": URL(fileURLWithPath: "/Applications/Xcode.app"),
        "dev.zed.Zed": URL(fileURLWithPath: "/Applications/Zed.app")
    ])
    discovery.refresh()

    #expect(discovery.installedEditors.map(\.id) == ["zed", "xcode"])
}

@MainActor
@Test func externalEditorDiscoveryFallsBackToSecondaryBundleID() {
    let previewURL = URL(fileURLWithPath: "/Applications/Zed Preview.app")
    let discovery = makeDiscovery(resolving: ["dev.zed.Zed-Preview": previewURL])
    discovery.refresh()

    #expect(discovery.installedEditors.map(\.id) == ["zed"])
    #expect(discovery.installedEditors.first?.bundleIdentifier == "dev.zed.Zed-Preview")
    #expect(discovery.installedEditors.first?.appURL == previewURL)
}

@MainActor
@Test func externalEditorDiscoveryListsEditorOnceWhenBothVariantsInstalled() {
    let stableURL = URL(fileURLWithPath: "/Applications/Zed.app")
    let discovery = makeDiscovery(resolving: [
        "dev.zed.Zed": stableURL,
        "dev.zed.Zed-Preview": URL(fileURLWithPath: "/Applications/Zed Preview.app")
    ])
    discovery.refresh()

    #expect(discovery.installedEditors.map(\.id) == ["zed"])
    #expect(discovery.installedEditors.first?.appURL == stableURL)
}

@MainActor
@Test func externalEditorDiscoveryCachesIconsAtRefreshTime() throws {
    let discovery = makeDiscovery(resolving: [
        "dev.zed.Zed": URL(fileURLWithPath: "/Applications/Zed.app")
    ])
    discovery.refresh()

    let zed = try #require(discovery.installedEditors.first)
    #expect(discovery.icon(for: zed) != nil)
    #expect(discovery.icon(for: installed("xcode")) == nil)
}

@Test func externalEditorResolveDefaultPrefersPreferredIDAndFallsBack() {
    let editors = [installed("zed"), installed("xcode")]

    #expect(ExternalEditorDiscovery.resolveDefault(editors: editors, preferredID: "xcode")?.id == "xcode")
    #expect(ExternalEditorDiscovery.resolveDefault(editors: editors, preferredID: "")?.id == "zed")
    #expect(ExternalEditorDiscovery.resolveDefault(editors: editors, preferredID: "nova")?.id == "zed")
    #expect(ExternalEditorDiscovery.resolveDefault(editors: [], preferredID: "zed") == nil)
}

@MainActor
@Test func externalEditorLauncherOpensProjectFolderWithEditorApp() {
    var openedFolder: URL?
    var openedApp: URL?
    let launcher = ExternalEditorLauncher { folderURL, appURL in
        openedFolder = folderURL
        openedApp = appURL
    }

    let zed = installed("zed")
    launcher.open(projectRoot: "/tmp/my-project", with: zed)

    #expect(openedFolder?.path == "/tmp/my-project")
    #expect(openedFolder?.hasDirectoryPath == true)
    #expect(openedApp == zed.appURL)
}

// MARK: - The Omni bar's editor rows

private func omniSources(editors: [OmniEditor], agents: [OmniAgent] = []) -> OmniSources {
    var sources = OmniSources()
    sources.window.hasProject = true
    sources.editors = editors
    sources.agents = agents
    return sources
}

@Test @MainActor func externalEditorOmniRowsNeedAProjectAndAnEditor() {
    let editors = [installed("zed")]
    #expect(OmniBarGathering.editors(editors, projectRoot: nil, preferredID: "").isEmpty)
    #expect(OmniBarGathering.editors([], projectRoot: "/tmp/p", preferredID: "").isEmpty)

    let none = OmniProviders.commands(omniSources(editors: [])).map(\.id)
    #expect(!none.contains { $0.hasPrefix("editor:") || $0 == "command:openInOtherEditor" })
}

@Test @MainActor func externalEditorOmniRowsOpenInTheDefaultThenOffersTheOthers() throws {
    let agent = OmniAgent(id: "codex", name: "Codex", commandLine: "codex")
    let editors = OmniBarGathering.editors([installed("zed"), installed("xcode")], projectRoot: "/tmp/p", preferredID: "")
    let items = OmniProviders.commands(omniSources(editors: editors, agents: [agent]))
    let ids = items.map(\.id)
    let editorIndex = try #require(ids.firstIndex(of: "editor:zed"))
    let otherIndex = try #require(ids.firstIndex(of: "command:openInOtherEditor"))
    let agentIndex = try #require(ids.firstIndex(of: "agent:codex"))
    #expect(editorIndex + 1 == otherIndex)
    #expect(otherIndex < agentIndex)
    #expect(items[editorIndex].title == "Open in Zed")
    #expect(items[editorIndex].primary == .openInEditor(editorID: "zed"))
    #expect(items[otherIndex].primary == .drill(.editors))
    // Open in Other Editor… lists every editor, the default first.
    #expect(OmniProviders.editors(omniSources(editors: editors)).map(\.title) == ["Zed", "Xcode"])
}

@Test @MainActor func externalEditorOmniRowsRespectTheDefaultEditorID() {
    let editors = OmniBarGathering.editors([installed("zed"), installed("xcode")], projectRoot: "/tmp/p", preferredID: "xcode")
    #expect(editors.map(\.id) == ["xcode", "zed"])
    let ids = OmniProviders.commands(omniSources(editors: editors)).map(\.id)
    #expect(ids.contains("editor:xcode"))
    #expect(!ids.contains("editor:zed"))
}

@Test @MainActor func externalEditorOmniRowsMatchTheQuery() {
    let sources = omniSources(editors: OmniBarGathering.editors([installed("zed"), installed("xcode")], projectRoot: "/tmp/p", preferredID: ""))
    func ids(_ query: String) -> [String] {
        OmniSections.build(scope: .commands, query: query, sources: sources, frecency: [:]).flatMap(\.rows).map(\.id)
    }
    #expect(ids("zed").first == "editor:zed")
    #expect(!ids("zed").contains("command:openInOtherEditor"))
    #expect(ids("other editor").first == "command:openInOtherEditor")
    #expect(!ids("other editor").contains("editor:zed"))
}
