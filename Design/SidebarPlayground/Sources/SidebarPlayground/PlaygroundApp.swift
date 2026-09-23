import AppKit
import SwiftUI

final class PlaygroundDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
}

@main
struct SidebarPlaygroundApp: App {
    @NSApplicationDelegateAdaptor(PlaygroundDelegate.self) var delegate
    @StateObject private var store = PlaygroundStore()
    var body: some Scene {
        Window("Cherry Sidebar Playground", id: "playground") {
            PlaygroundView(store: store)
                .preferredColorScheme(.dark)
                .tint(Color(red: 0.60, green: 0.83, blue: 0.72))
        }
        .defaultSize(width: 1180, height: 810)
        .windowResizability(.contentMinSize)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(after: .importExport) {
                Button("Import Sidebar Settings…", action: store.importJSON).keyboardShortcut("o")
                Button("Export Sidebar Settings…", action: store.exportJSON).keyboardShortcut("e")
                Button("Copy Swift Values", action: store.copySwift).keyboardShortcut("c", modifiers: [.command, .shift])
            }
            CommandMenu("Preview") {
                Toggle("Compare with Current Cherry", isOn: $store.comparing).keyboardShortcut("b")
                Button("Reset to Current Cherry") { store.apply(.current) }.keyboardShortcut("r", modifiers: [.command, .shift])
            }
        }
    }
}

struct PlaygroundView: View {
    @ObservedObject var store: PlaygroundStore
    @StateObject private var preview = PreviewState()
    @State private var presetName = ""
    @State private var showSave = false
    @State private var showInspector = true
    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            HStack(spacing: 0) {
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text(store.comparing ? "Current Cherry" : "Live preview").font(.system(size: 12, weight: .medium))
                        Spacer()
                        Text("\(Int(store.displayed.sidebarWidth)) pt sidebar").font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
                    }
                    SidebarPreview(tuning: store.displayed, state: preview)
                    HStack {
                        Text(preview.status).font(.system(size: 11)).foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                        Button("Reset scene") { preview.reset() }.buttonStyle(.plain).font(.system(size: 11))
                    }
                }.padding(20).frame(maxWidth: .infinity, maxHeight: .infinity)
                if showInspector {
                    Divider()
                    inspector.frame(width: 300)
                }
            }
            Divider()
            HStack {
                Text(store.message).font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text("Export a preset to apply this design in Cherry.").font(.system(size: 11)).foregroundStyle(.secondary)
            }.padding(.horizontal, 20).frame(height: 32)
        }
        .background(Color(white: 0.09))
        .frame(minWidth: showInspector ? 1020 : 720, minHeight: 650)
        .alert("Couldn’t load or save settings", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .sheet(isPresented: $showSave) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Save a variation").font(.title3.weight(.medium))
                TextField("Preset name", text: $presetName).textFieldStyle(.roundedBorder)
                    .onSubmit(saveVariation)
                Text("Use an existing name to update that variation.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Spacer()
                    Button("Cancel") { showSave = false }.keyboardShortcut(.cancelAction)
                    Button("Save", action: saveVariation).keyboardShortcut(.defaultAction)
                        .disabled(presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(24).frame(width: 330)
        }
    }
    private func saveVariation() {
        guard !presetName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        store.savePreset(presetName); showSave = false; presetName = ""
    }
    private var toolbar: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Sidebar playground").font(.system(size: 16, weight: .medium))
                Text("Tune it. Try it. Keep what works.").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            Picker("Scene", selection: $preview.scenario) {
                ForEach(Scenario.allCases) { Text($0.rawValue).tag($0) }
            }.labelsHidden().frame(width: 155).help("Preview a different workspace state")
            Toggle("Compare", isOn: $store.comparing).toggleStyle(.button)
                .help("Show current Cherry values without losing your changes (⌘B)")
            Button { withAnimation(.easeInOut(duration: 0.15)) { showInspector.toggle() } } label: {
                Image(systemName: "slider.horizontal.3")
            }.help("Show or hide controls").accessibilityLabel("Toggle controls")
            Button("Export…", action: store.exportJSON).buttonStyle(.borderedProminent)
        }.controlSize(.regular).padding(.horizontal, 20).frame(height: 72)
    }
    private var inspector: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "slider.horizontal.3").foregroundStyle(.secondary)
                Text("Dials").font(.system(size: 13, weight: .semibold))
                Spacer()
                Menu {
                    Button("Current Cherry") { store.apply(.current) }
                    Button("Compact") { store.apply(.compact) }
                    Button("Airy") { store.apply(.airy) }
                    if !store.presets.isEmpty {
                        Divider()
                        ForEach(store.presets) { preset in
                            Button(preset.name) { store.apply(preset.tuning) }
                        }
                    }
                } label: { Text("Presets") }.fixedSize()
            }.padding(16)
            Divider()
            if store.comparing {
                Text("Comparing with current Cherry. Turn Compare off to edit.")
                    .font(.system(size: 12)).foregroundStyle(.secondary).padding(16)
            }
            ScrollView {
                VStack(spacing: 0) {
                    DialSection(title: "Layout") {
                        dial("Sidebar width", \.sidebarWidth)
                        dial("Left inset", \.leftInset)
                        dial("Row height", \.rowHeight)
                        dial("Row gap", \.rowGap)
                        dial("Folder gap", \.folderGap)
                    }
                    DialSection(title: "Icons") {
                        dial("Max icon size", \.iconSize)
                        dial("Icon column", \.iconSlot)
                        dial("Icon to text", \.iconGap)
                        toggle("Alignment guides", \.iconGuides)
                        toggle("Folder icons", \.folderIcons)
                        toggle("Disclosure chevrons", \.chevrons)
                        toggle("Monochrome logos", \.templateIcons)
                        Text("Visible glyph edges align left. Transparent padding is trimmed; proportions stay intact.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    DialSection(title: "Sub-agents", initiallyExpanded: false) {
                        Button("Show sub-agent example") { preview.scenario = .subAgents }
                            .controlSize(.small)
                        dial("Child indent", \.subAgentIndent)
                        dial("Child spacing", \.subAgentGap)
                        dial("Guide offset", \.treeGuideOffset)
                        dial("Guide opacity", \.treeGuideOpacity, step: 0.01, percent: true)
                        toggle("Tree guides", \.treeGuides)
                        toggle("Status indicators", \.agentStatus)
                        toggle("Animate loading", \.loadingIndicators)
                        Text("Click an agent count to fold its children. Right-click a parent to add a sample sub-agent.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    DialSection(title: "Type", initiallyExpanded: false) {
                        dial("Row text", \.textSize)
                        dial("Folder text", \.headerSize)
                        Picker("Weight", selection: value(\.textWeight)) {
                            Text("Regular").tag(0.0); Text("Medium").tag(1.0); Text("Semibold").tag(2.0)
                        }.font(.system(size: 12))
                        toggle("Subtitles", \.subtitles)
                        toggle("Keyboard hints", \.showShortcuts)
                    }
                    DialSection(title: "Selection", initiallyExpanded: false) {
                        dial("Side inset", \.selectionInset)
                        dial("Corner radius", \.selectionRadius)
                        dial("Selected opacity", \.selectedOpacity, step: 0.01, percent: true)
                        dial("Hover opacity", \.hoverOpacity, step: 0.01, percent: true)
                    }
                    DialSection(title: "Colors", initiallyExpanded: false) {
                        color("Sidebar", \.sidebarColor)
                        color("Content", \.contentColor)
                        color("Text & icons", \.textColor)
                        color("Highlight", \.highlightColor)
                        HStack {
                            Button("Dark") { palette(light: false) }
                            Button("Light") { palette(light: true) }
                            Spacer()
                        }.controlSize(.small)
                    }
                    DialSection(title: "Project tools", initiallyExpanded: false) {
                        toggle("Commands & Notes", \.showTools)
                        Text("Click headers to expand them. Add sample terminals and folders using + in the preview.")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }.disabled(store.comparing)
            }
            Divider()
            VStack(spacing: 10) {
                HStack {
                    Button("Save variation…") { showSave = true }
                    Spacer()
                    Button("Reset") { store.apply(.current) }.help("Restore current Cherry’s values")
                }
                HStack {
                    Button("Import…", action: store.importJSON)
                    Spacer()
                    Button("Copy Swift", action: store.copySwift)
                }
            }.controlSize(.small).padding(16)
        }.background(Color(white: 0.12))
    }
    private func value<V>(_ path: WritableKeyPath<Tuning, V>) -> Binding<V> {
        Binding(get: { store.tuning[keyPath: path] }, set: { store.tuning[keyPath: path] = $0 })
    }
    private func dial(_ title: String, _ path: WritableKeyPath<Tuning, Double>, step: Double = 1, percent: Bool = false) -> some View {
        VStack(spacing: 7) {
            HStack {
                Text(title).font(.system(size: 12))
                Spacer()
                Text(percent ? "\(Int((store.tuning[keyPath: path] * 100).rounded()))%" : "\(Int(store.tuning[keyPath: path]))")
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(.secondary)
            }
            Slider(value: value(path), in: Tuning.ranges[path]!, step: step)
                .controlSize(.small).accessibilityLabel(title)
        }
    }
    private func toggle(_ title: String, _ path: WritableKeyPath<Tuning, Bool>) -> some View {
        Toggle(title, isOn: value(path)).font(.system(size: 12)).toggleStyle(.switch).controlSize(.mini)
    }
    private func color(_ title: String, _ path: WritableKeyPath<Tuning, String>) -> some View {
        HStack {
            ColorPicker(title, selection: Binding(get: { Color(hex: store.tuning[keyPath: path]) }, set: { store.tuning[keyPath: path] = $0.hex }), supportsOpacity: false)
                .font(.system(size: 12))
            Text(store.tuning[keyPath: path]).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
        }
    }
    private func palette(light: Bool) {
        store.tuning.sidebarColor = light ? "#ECECEC" : "#2E2E2E"
        store.tuning.contentColor = light ? "#FAFAFA" : "#202020"
        store.tuning.textColor = light ? "#353535" : "#D0D0D0"
        store.tuning.highlightColor = light ? "#000000" : "#FFFFFF"
    }
}

private struct DialSection<Content: View>: View {
    let title: String
    @State private var expanded: Bool
    let content: Content
    init(title: String, initiallyExpanded: Bool = true, @ViewBuilder content: () -> Content) {
        self.title = title; _expanded = State(initialValue: initiallyExpanded); self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button { expanded.toggle() } label: {
                HStack {
                    Text(title).font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Image(systemName: expanded ? "minus" : "plus").font(.system(size: 10)).foregroundStyle(.secondary)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityLabel("\(expanded ? "Collapse" : "Expand") \(title) controls")
            if expanded { content }
        }.padding(16)
        Divider()
    }
}
