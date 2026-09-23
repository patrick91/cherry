import Foundation
import Testing
@testable import SidebarPlayground

@Test func presetsRoundTripWithoutLosingChanges() throws {
    var value = Tuning.airy
    value.iconSize = 21; value.folderIcons = true; value.sidebarColor = "#123456"
    let restored = try JSONDecoder().decode(Tuning.self, from: value.json()).validated()
    #expect(restored == value)
}
@Test func invalidImportsAreRejected() throws {
    var value = Tuning.current
    value.iconSize = 1000
    #expect(throws: TuningError.self) { try value.validated() }
    value = .current; value.version = 42
    #expect(throws: TuningError.self) { try value.validated() }
    value = .current; value.textColor = "red"
    #expect(throws: TuningError.self) { try value.validated() }
}
@Test @MainActor func variationsAndLatestValuesSurviveRelaunch() throws {
    let domain = "cherry-playground-test-\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: domain))
    defer { defaults.removePersistentDomain(forName: domain) }
    let store = PlaygroundStore(defaults: defaults)
    store.tuning.leftInset = 5; store.savePreset("My sidebar")
    store.tuning.leftInset = 7; store.savePreset("My sidebar")
    let restored = PlaygroundStore(defaults: defaults)
    #expect(restored.tuning.leftInset == 7)
    #expect(restored.presets.count == 1)
    #expect(restored.presets[0].tuning.leftInset == 7)
    restored.comparing = true
    #expect(restored.displayed == .current)
    #expect(restored.tuning.leftInset == 7)
}
@Test @MainActor func emptyScenesCanBePopulatedAndReset() {
    let preview = PreviewState()
    preview.scenario = .emptyProject
    #expect(preview.folders.isEmpty)
    preview.addFolder()
    preview.addTerminal(to: preview.folders[0].id, title: "Codex", logo: "openai")
    #expect(preview.selected?.title == "Codex")
    preview.reset()
    #expect(preview.folders.isEmpty)
    #expect(preview.selectedID == nil)
}

@Test func olderPresetsKeepValuesAndGainTreeDefaults() throws {
    var fields = try #require(JSONSerialization.jsonObject(with: Tuning.compact.json()) as? [String: Any])
    for key in ["subAgentIndent", "subAgentGap", "treeGuideOpacity", "treeGuideOffset", "loadingIndicators", "treeGuides", "agentStatus", "iconGuides"] {
        fields.removeValue(forKey: key)
    }
    let restored = try JSONDecoder().decode(Tuning.self, from: JSONSerialization.data(withJSONObject: fields)).validated()
    #expect(restored == .compact)
}

@Test @MainActor func agentTreeSelectionCollapseAndCloseStayConsistent() throws {
    let preview = PreviewState(); preview.scenario = .subAgents
    let folder = preview.folders[0]
    #expect(preview.children(of: "codex", in: folder).count == 3)
    #expect(preview.selectedID == "research")
    preview.toggleChildren(of: "codex", in: folder)
    #expect(preview.selectedID == "codex")
    #expect(!preview.visibleRows(in: folder).contains { $0.id == "research" })
    let parent = try #require(folder.rows.first { $0.id == "codex" })
    preview.addSubAgent(to: parent, in: folder.id)
    #expect(preview.selected?.parentID == "codex")
    #expect(!preview.collapsedAgents.contains("codex"))
    preview.close(parent, in: folder.id)
    #expect(preview.selectedID == nil)
    #expect(!preview.folders[0].rows.contains { $0.id == "codex" || $0.parentID == "codex" })
    #expect(preview.folders[0].rows.contains { $0.id == "review" })
}

@Test func guideOffsetStartsAtParentLeftEdgeAndKeepsElbowsValid() {
    var tuning = Tuning.current
    #expect(tuning.treeGuideX == tuning.leftInset)
    tuning.treeGuideOffset = -8
    #expect(tuning.treeGuideX == 4)
    tuning.leftInset = 0
    #expect(tuning.treeGuideX == 0)
    tuning.subAgentIndent = 12; tuning.treeGuideOffset = 16
    #expect(tuning.treeGuideX <= tuning.leftInset + tuning.subAgentIndent - 4)
}

@Test @MainActor func sampleIncludesWorkingReadyAndDoneAgents() {
    let preview = PreviewState(); preview.scenario = .subAgents
    let states = Set(preview.folders.flatMap(\.rows).compactMap(\.status))
    #expect(states.isSuperset(of: ["Working", "Starting", "Ready", "Done"]))
    var tuning = Tuning.current
    tuning.treeGuideOffset = -5; tuning.loadingIndicators = false
    #expect((try? JSONDecoder().decode(Tuning.self, from: tuning.json()).validated()) == tuning)
}
