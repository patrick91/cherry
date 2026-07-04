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

@MainActor
@Test func externalEditorRootItemsHiddenWithoutProjectOrEditors() {
    let noProject = CommandPaletteRootItem.filteredItems(
        query: "",
        agents: [],
        projects: [],
        installedEditors: [installed("zed")],
        hasOpenProject: false
    )
    #expect(!noProject.map(\.id).contains { $0.hasPrefix("editor:") || $0 == "command:openInOtherEditor" })

    let noEditors = CommandPaletteRootItem.filteredItems(
        query: "",
        agents: [],
        projects: [],
        installedEditors: [],
        hasOpenProject: true
    )
    #expect(!noEditors.map(\.id).contains { $0.hasPrefix("editor:") || $0 == "command:openInOtherEditor" })
}

@MainActor
@Test func externalEditorRootItemsOrderedAfterCommandsBeforeAgents() throws {
    let agent = ResolvedAgentTool(
        definition: AgentToolDefinition(name: "Codex", command: "codex"),
        source: .global
    )
    let items = CommandPaletteRootItem.filteredItems(
        query: "",
        agents: [agent],
        projects: [],
        installedEditors: [installed("zed"), installed("xcode")],
        hasOpenProject: true
    )
    let ids = items.map(\.id)

    let editorIndex = try #require(ids.firstIndex(of: "editor:zed"))
    let otherIndex = try #require(ids.firstIndex(of: "command:openInOtherEditor"))
    let agentIndex = try #require(ids.firstIndex(of: "agent:codex"))
    let lastCommandIndex = try #require(ids.lastIndex(of: "command:toggleAppearance"))

    #expect(lastCommandIndex < editorIndex)
    #expect(editorIndex + 1 == otherIndex)
    #expect(otherIndex < agentIndex)
    #expect(items[editorIndex].title == "Open in Zed")
}

@MainActor
@Test func externalEditorRootItemsRespectDefaultEditorID() {
    let items = CommandPaletteRootItem.filteredItems(
        query: "",
        agents: [],
        projects: [],
        installedEditors: [installed("zed"), installed("xcode")],
        defaultEditorID: "xcode",
        hasOpenProject: true
    )

    #expect(items.map(\.id).contains("editor:xcode"))
    #expect(!items.map(\.id).contains("editor:zed"))
}

@MainActor
@Test func externalEditorRootItemsMatchQuery() {
    let editors = [installed("zed"), installed("xcode")]

    let zedQuery = CommandPaletteRootItem.filteredItems(
        query: "zed",
        agents: [],
        projects: [],
        installedEditors: editors,
        hasOpenProject: true
    ).map(\.id)
    #expect(zedQuery.contains("editor:zed"))
    #expect(!zedQuery.contains("command:openInOtherEditor"))

    let otherQuery = CommandPaletteRootItem.filteredItems(
        query: "other editor",
        agents: [],
        projects: [],
        installedEditors: editors,
        hasOpenProject: true
    ).map(\.id)
    #expect(otherQuery.contains("command:openInOtherEditor"))
    #expect(!otherQuery.contains("editor:zed"))
}
