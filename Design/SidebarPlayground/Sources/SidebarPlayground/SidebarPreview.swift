import AppKit
import SwiftUI

enum Scenario: String, CaseIterable, Identifiable {
    case populated = "Populated"
    case subAgents = "Sub-agents"
    case emptyProject = "No projects"
    case emptyFolder = "Empty folder"
    case nothingOpen = "Nothing selected"
    case longNames = "Long names"
    var id: String { rawValue }
}

struct SampleRow: Identifiable, Equatable {
    var id: String
    var title: String
    var detail: String
    var symbol = "terminal"
    var logo: String? = nil
    var parentID: String? = nil
    var status: String? = nil
}
struct SampleFolder: Identifiable {
    var id: String
    var name: String
    var rows: [SampleRow]
}

@MainActor
final class PreviewState: ObservableObject {
    @Published var scenario: Scenario = .populated { didSet { reset() } }
    @Published var folders: [SampleFolder] = []
    @Published var selectedID: String? = "codex"
    @Published var collapsedAgents: Set<String> = []
    @Published var collapsedFolders: Set<String> = []
    @Published var commandsExpanded = true
    @Published var notesExpanded = true
    @Published var noteAdded = false
    @Published var commandAdded = false
    @Published var status = "Interactive sample data · no processes are launched."
    var selected: SampleRow? { folders.flatMap(\.rows).first { $0.id == selectedID } }
    init() { reset() }
    func reset() {
        let rows = [SampleRow(id: "shell", title: "Shell", detail: "~/github/cherry"),
                    SampleRow(id: "codex", title: "Codex", detail: "Review sidebar layout", logo: "openai", status: "Working"),
                    SampleRow(id: "claude", title: "Claude", detail: "Improve empty states", logo: "claude", status: "Starting"),
                    SampleRow(id: "nvim", title: "README.md", detail: "nvim README.md", logo: "neovim")]
        folders = [SampleFolder(id: "cherry", name: "cherry", rows: rows),
                   SampleFolder(id: "website", name: "website", rows: [SampleRow(id: "python", title: "Python", detail: "python3 -m http.server", logo: "python")]),
                   SampleFolder(id: "docs", name: "docs", rows: [])]
        collapsedAgents = []; collapsedFolders = []; selectedID = "codex"; noteAdded = false; commandAdded = false
        switch scenario {
        case .emptyProject: folders = []; selectedID = nil
        case .emptyFolder: folders = [SampleFolder(id: "cherry", name: "cherry", rows: [])]; selectedID = nil
        case .nothingOpen: selectedID = nil
        case .longNames:
            folders[0].name = "customer-experience-platform"
            folders[0].rows[1].title = "Investigate reconnect behavior after sleep"
            folders[0].rows[2].title = "Claude · review authentication changes"
            folders[1].name = "website / packages / documentation"
        case .subAgents:
            folders[0].rows.insert(contentsOf: [
                SampleRow(id: "research", title: "Research", detail: "Find reconnect edge cases", logo: "openai", parentID: "codex", status: "Working"),
                SampleRow(id: "implementation", title: "Implementation", detail: "Update the connection flow", logo: "openai", parentID: "codex", status: "Ready"),
                SampleRow(id: "tests", title: "Tests", detail: "Check session persistence", logo: "openai", parentID: "codex", status: "Done")
            ], at: 2)
            folders[0].rows.insert(SampleRow(id: "review", title: "Design review", detail: "Review the empty states", logo: "claude", parentID: "claude", status: "Working"), at: 6)
            selectedID = "research"
        case .populated: break
        }
    }
    func visibleRows(in folder: SampleFolder) -> [SampleRow] {
        folder.rows.filter { $0.parentID.map { !collapsedAgents.contains($0) } ?? true }
    }
    func children(of parent: String, in folder: SampleFolder) -> [SampleRow] {
        folder.rows.filter { $0.parentID == parent }
    }
    func toggleChildren(of parent: String, in folder: SampleFolder) {
        if collapsedAgents.contains(parent) { collapsedAgents.remove(parent) }
        else {
            collapsedAgents.insert(parent)
            if children(of: parent, in: folder).contains(where: { $0.id == selectedID }) { selectedID = parent }
        }
    }
    func close(_ row: SampleRow, in folderID: String) {
        guard let index = folders.firstIndex(where: { $0.id == folderID }) else { return }
        let removed = Set(folders[index].rows.filter { $0.id == row.id || $0.parentID == row.id }.map(\.id))
        folders[index].rows.removeAll { removed.contains($0.id) }
        collapsedAgents.remove(row.id)
        if let selectedID, removed.contains(selectedID) { self.selectedID = nil }
    }
    func addSubAgent(to parent: SampleRow, in folderID: String) {
        guard let index = folders.firstIndex(where: { $0.id == folderID }),
              let parentIndex = folders[index].rows.firstIndex(where: { $0.id == parent.id }) else { return }
        let count = children(of: parent.id, in: folders[index]).count
        let row = SampleRow(id: UUID().uuidString, title: "Sub-agent \(count + 1)", detail: "Sample delegated task", logo: parent.logo, parentID: parent.id, status: "Ready")
        folders[index].rows.insert(row, at: parentIndex + count + 1)
        collapsedAgents.remove(parent.id); selectedID = row.id
    }
    func addFolder() {
        folders.append(SampleFolder(id: UUID().uuidString, name: folders.isEmpty ? "cherry" : "new-folder", rows: []))
        status = "Added a sample folder."
    }
    func addTerminal(to folder: String, title: String = "Shell", logo: String? = nil) {
        guard let index = folders.firstIndex(where: { $0.id == folder }) else { return }
        let row = SampleRow(id: UUID().uuidString, title: title, detail: "Sample session", logo: logo)
        folders[index].rows.append(row); selectedID = row.id; collapsedFolders.remove(folder)
    }
}

struct PreviewIcon: View {
    var symbol: String = "terminal"
    var logo: String? = nil
    let tuning: Tuning
    var body: some View {
        Group {
            if let image = LogoResources.image(logo: logo, symbol: symbol) {
                let size = IconGeometry.fitted(image.size, maximum: tuning.iconSize)
                Image(nsImage: image).resizable()
                    .renderingMode(logo == nil || tuning.templateIcons ? .template : .original)
                    .interpolation(.high)
                    .frame(width: size.width, height: size.height)
            }
        }
        .frame(width: max(tuning.iconSlot, tuning.iconSize), height: tuning.iconSize, alignment: .leading)
        .accessibilityHidden(true)
    }
}

@MainActor
private enum LogoResources {
    static var cache: [String: NSImage] = [:]
    static func image(logo: String?, symbol: String) -> NSImage? {
        let key = logo.map { "logo:" + $0 } ?? "symbol:" + symbol
        if let cached = cache[key] { return cached }
        let source: NSImage?
        if let logo {
            let packaged = Bundle.main.resourceURL?.appendingPathComponent("CherrySidebarPlayground_SidebarPlayground.bundle")
            let bundle = packaged.flatMap(Bundle.init(url:)) ?? Bundle.module
            source = bundle.url(forResource: logo, withExtension: "svg", subdirectory: "Resources").flatMap(NSImage.init(contentsOf:))
        } else {
            source = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 64, weight: .regular))
        }
        guard let source else { return nil }
        let normalized = IconGeometry.normalized(source)
        cache[key] = normalized
        return normalized
    }
}

struct AgentStatusIndicator: View {
    let status: String
    let animated: Bool
    let color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private var isLoading: Bool { status == "Working" || status == "Starting" }

    var body: some View {
        Group {
            if isLoading && animated && !reduceMotion {
                TimelineView(.animation(minimumInterval: 1.0 / 12)) { context in
                    let phase = Int(context.date.timeIntervalSinceReferenceDate * 12) % 12
                    ZStack {
                        ForEach(0..<12) { index in
                            Capsule()
                                .fill(color.opacity(Double((index - phase + 12) % 12 + 1) / 12))
                                .frame(width: 1.3, height: 3)
                                .offset(y: -4.5)
                                .rotationEffect(.degrees(Double(index) * 30))
                        }
                    }.frame(width: 12, height: 12)
                }
            } else if isLoading {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold))
            } else if status == "Done" {
                Image(systemName: "checkmark").font(.system(size: 10, weight: .medium)).foregroundStyle(.green)
            } else {
                Circle().fill(.secondary).frame(width: 5, height: 5)
            }
        }
        .help(status)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(status)
    }
}

struct PreviewRow: View {
    let row: SampleRow
    let tuning: Tuning
    var selected = false
    var shortcut: String? = nil
    var childCount = 0
    var childrenExpanded = true
    var isLastChild = false
    var toggleChildren: (() -> Void)? = nil
    let action: () -> Void
    @State private var hovered = false
    private var weight: Font.Weight { [.regular, .medium, .semibold][Int(tuning.textWeight.rounded())] }
    var body: some View {
        Button(action: action) {
            HStack(spacing: tuning.iconGap) {
                PreviewIcon(symbol: row.symbol, logo: row.logo, tuning: tuning)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title).font(.system(size: tuning.textSize, weight: weight)).lineLimit(1)
                    if tuning.subtitles {
                        Text(row.detail).font(.system(size: max(10, tuning.textSize - 2)))
                            .opacity(0.6).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                if tuning.agentStatus, let status = row.status {
                    AgentStatusIndicator(status: status, animated: tuning.loadingIndicators, color: Color(hex: tuning.textColor))
                        .frame(width: 14, height: 14)
                }
                if tuning.showShortcuts, let shortcut {
                    Text(shortcut).font(.system(size: 11)).opacity(0.45)
                }
            }
            .padding(.leading, tuning.leftInset + (row.parentID == nil ? 0 : tuning.subAgentIndent))
            .padding(.trailing, childCount > 0 ? 74 : 12)
            .frame(height: max(tuning.rowHeight, tuning.subtitles ? tuning.textSize * 2 + 10 : tuning.iconSize + 6))
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background {
                RoundedRectangle(cornerRadius: tuning.selectionRadius)
                    .fill(Color(hex: tuning.highlightColor).opacity(selected ? tuning.selectedOpacity : hovered ? tuning.hoverOpacity : 0))
                    .padding(.horizontal, tuning.selectionInset)
            }
        }
        .buttonStyle(.plain).foregroundStyle(Color(hex: tuning.textColor))
        .overlay(alignment: .trailing) {
            if childCount > 0, let toggleChildren {
                Button(action: toggleChildren) {
                    Text("\(childCount) \(childCount == 1 ? "agent" : "agents")").font(.system(size: 10)).foregroundStyle(Color(hex: tuning.textColor).opacity(0.6))
                        .padding(.horizontal, 8).frame(height: tuning.rowHeight)
                }
                .buttonStyle(.plain).padding(.trailing, 4)
                .accessibilityLabel("\(childrenExpanded ? "Collapse" : "Expand") sub-agents of \(row.title)")
                .help("\(childrenExpanded ? "Hide" : "Show") \(childCount) sub-agents")
            }
        }
        .overlay(alignment: .leading) {
            if row.parentID != nil && tuning.treeGuides {
                GeometryReader { proxy in
                    Path { path in
                        let x = tuning.treeGuideX
                        let center = proxy.size.height / 2
                        path.move(to: CGPoint(x: x, y: -tuning.subAgentGap))
                        path.addLine(to: CGPoint(x: x, y: isLastChild ? center : proxy.size.height))
                        path.move(to: CGPoint(x: x, y: center))
                        path.addLine(to: CGPoint(x: tuning.leftInset + tuning.subAgentIndent - 4, y: center))
                    }.stroke(Color(hex: tuning.textColor).opacity(tuning.treeGuideOpacity), lineWidth: 1)
                }.allowsHitTesting(false).accessibilityHidden(true)
            }
        }
        .onHover { hovered = $0 }
        .help(row.title + "\n" + row.detail)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }
}

struct SidebarPreview: View {
    let tuning: Tuning
    @ObservedObject var state: PreviewState
    var body: some View {
        HStack(spacing: 0) {
            sidebar.frame(width: tuning.sidebarWidth)
            Rectangle().fill(Color(hex: tuning.textColor).opacity(0.08)).frame(width: 1)
            content.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .foregroundStyle(Color(hex: tuning.textColor))
        .background(Color(hex: tuning.contentColor))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.08)))
    }
    private var sidebar: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack(spacing: 6) {
                    ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color.yellow, Color.green], id: \.self) { color in
                        Circle().fill(color).frame(width: 10, height: 10)
                    }
                }.accessibilityHidden(true)
                Text("Cherry").font(.system(size: 13, weight: .semibold))
                Spacer(minLength: 0)
            }.padding(.horizontal, 14).frame(height: 48)
            ScrollView {
                VStack(alignment: .leading, spacing: tuning.folderGap) {
                    ForEach(state.folders) { folder in
                        folderSection(folder)
                    }
                    if state.folders.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Your projects live here").font(.system(size: tuning.headerSize, weight: .medium))
                            Text("Add a folder to get started.").font(.system(size: 12)).opacity(0.6)
                        }.padding(.horizontal, tuning.leftInset).padding(.vertical, 14)
                    }
                    PreviewRow(row: .init(id: "add-folder", title: "Add folder", detail: "", symbol: "plus"), tuning: tuning) { state.addFolder() }
                        .opacity(0.65)
                }.padding(.bottom, 12)
            }
            if tuning.showTools && !state.folders.isEmpty {
                tools
            }
        }.background(Color(hex: tuning.sidebarColor))
        .overlay {
            if tuning.iconGuides {
                GeometryReader { proxy in
                    Path { path in
                        for x in [tuning.leftInset, tuning.leftInset + max(tuning.iconSlot, tuning.iconSize)] {
                            path.move(to: CGPoint(x: x, y: 48))
                            path.addLine(to: CGPoint(x: x, y: proxy.size.height))
                        }
                    }.stroke(Color.cyan.opacity(0.65), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                }.allowsHitTesting(false).accessibilityHidden(true)
            }
        }
    }
    private func folderSection(_ folder: SampleFolder) -> some View {
        VStack(spacing: 0) {
            HStack(spacing: tuning.iconGap) {
                Button {
                    if tuning.chevrons {
                        if state.collapsedFolders.contains(folder.id) { state.collapsedFolders.remove(folder.id) }
                        else { state.collapsedFolders.insert(folder.id) }
                    } else { state.selectedID = nil }
                } label: {
                    HStack(spacing: tuning.iconGap) {
                        if tuning.chevrons {
                            Image(systemName: state.collapsedFolders.contains(folder.id) ? "chevron.right" : "chevron.down")
                                .font(.system(size: 9)).frame(width: 10)
                        }
                        if tuning.folderIcons { PreviewIcon(symbol: "folder", tuning: tuning) }
                        Text(folder.name).font(.system(size: tuning.headerSize, weight: .medium)).lineLimit(1)
                        Spacer(minLength: 0)
                    }.contentShape(Rectangle())
                }.buttonStyle(.plain).help(folder.name)
                Menu {
                    Button("Shell") { state.addTerminal(to: folder.id) }
                    Button("Codex") { state.addTerminal(to: folder.id, title: "Codex", logo: "openai") }
                    Button("Claude") { state.addTerminal(to: folder.id, title: "Claude", logo: "claude") }
                } label: { Image(systemName: "plus").font(.system(size: 12)) }
                .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                .accessibilityLabel("Add sample terminal to \(folder.name)")
            }.padding(.leading, tuning.leftInset).padding(.trailing, 12).frame(height: tuning.rowHeight)
            if !tuning.chevrons || !state.collapsedFolders.contains(folder.id) {
                ForEach(Array(state.visibleRows(in: folder).enumerated()), id: \.element.id) { index, row in
                    let children = state.children(of: row.id, in: folder)
                    PreviewRow(row: row, tuning: tuning, selected: state.selectedID == row.id, shortcut: "⌘\(index + 1)",
                               childCount: children.count, childrenExpanded: !state.collapsedAgents.contains(row.id),
                               isLastChild: row.parentID.map { state.children(of: $0, in: folder).last?.id == row.id } ?? false,
                               toggleChildren: { state.toggleChildren(of: row.id, in: folder) }) {
                        state.selectedID = row.id
                    }
                    .padding(.top, row.parentID == nil ? tuning.rowGap : tuning.subAgentGap)
                    .contextMenu {
                        if row.parentID == nil && ["openai", "claude"].contains(row.logo ?? "") {
                            Button("Add sample sub-agent") { state.addSubAgent(to: row, in: folder.id) }
                        }
                        Button("Close sample session") { state.close(row, in: folder.id) }
                    }
                }
                if folder.rows.isEmpty {
                    PreviewRow(row: .init(id: "empty", title: "Open terminal", detail: "", symbol: "terminal"), tuning: tuning) {
                        state.addTerminal(to: folder.id)
                    }.opacity(0.6)
                }
            }
        }
    }
    private var tools: some View {
        VStack(spacing: 4) {
            Rectangle().fill(Color(hex: tuning.textColor).opacity(0.08)).frame(height: 1).padding(.bottom, 8)
            toolHeader("Commands", symbol: "play", expanded: $state.commandsExpanded) {
                state.commandAdded = true; state.commandsExpanded = true
            }
            if state.commandsExpanded {
                PreviewRow(row: .init(id: "command", title: "Dev server", detail: "website", symbol: "play.fill"), tuning: tuning, selected: state.selectedID == "command") { state.selectedID = "command" }
                if state.commandAdded {
                    PreviewRow(row: .init(id: "test", title: "Run tests", detail: "cherry", symbol: "play.fill"), tuning: tuning, selected: state.selectedID == "test") { state.selectedID = "test" }
                }
            }
            toolHeader("Notes", symbol: "note.text", expanded: $state.notesExpanded) {
                state.noteAdded = true; state.notesExpanded = true
            }
            if state.notesExpanded {
                PreviewRow(row: .init(id: "note", title: "Sidebar ideas", detail: "Edited just now", symbol: "note.text"), tuning: tuning, selected: state.selectedID == "note") { state.selectedID = "note" }
                if state.noteAdded {
                    PreviewRow(row: .init(id: "new-note", title: "Untitled note", detail: "Just now", symbol: "note.text"), tuning: tuning, selected: state.selectedID == "new-note") { state.selectedID = "new-note" }
                }
            }
        }.padding(.bottom, 12)
    }
    private func toolHeader(_ title: String, symbol: String, expanded: Binding<Bool>, add: @escaping () -> Void) -> some View {
        HStack(spacing: tuning.iconGap) {
            Button { expanded.wrappedValue.toggle() } label: {
                HStack(spacing: tuning.iconGap) {
                    if tuning.chevrons {
                        Image(systemName: expanded.wrappedValue ? "chevron.down" : "chevron.right").font(.system(size: 9)).frame(width: 10)
                    }
                    PreviewIcon(symbol: symbol, tuning: tuning)
                    Text(title).font(.system(size: tuning.headerSize, weight: .medium))
                    Spacer(minLength: 0)
                }.contentShape(Rectangle())
            }.buttonStyle(.plain)
            Button(action: add) { Image(systemName: "plus").font(.system(size: 12)).frame(width: 20, height: 24) }
                .buttonStyle(.plain).accessibilityLabel("Add sample \(title.lowercased())")
        }.padding(.leading, tuning.leftInset).padding(.trailing, 8).frame(height: tuning.rowHeight)
    }
    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                if let selected = state.selected {
                    PreviewIcon(symbol: selected.symbol, logo: selected.logo, tuning: tuning)
                    Text("~/github/cherry  /  \(selected.title)").lineLimit(1)
                } else { Text(state.selectedID == nil ? "Cherry" : "Project tools") }
                Spacer(minLength: 0)
            }.font(.system(size: 11)).opacity(0.65).padding(.horizontal, 16).frame(height: 48)
            Rectangle().fill(Color(hex: tuning.textColor).opacity(0.08)).frame(height: 1)
            if let selected = state.selected {
                sampleTerminal(selected)
            } else if state.selectedID == "note" || state.selectedID == "new-note" {
                VStack(alignment: .leading, spacing: 16) {
                    Text(state.selectedID == "note" ? "Sidebar ideas" : "Untitled note").font(.title2.weight(.medium))
                    Text("Keep the chrome quiet.\nGive the running work the space.\nMake the next action obvious.")
                        .font(.system(size: 14)).lineSpacing(8).opacity(0.75)
                    Spacer()
                }.padding(28)
            } else if state.selectedID == "command" || state.selectedID == "test" {
                VStack(alignment: .leading, spacing: 12) {
                    Text(state.selectedID == "command" ? "$ npm run dev" : "$ swift test").font(.system(size: 13, design: .monospaced))
                    Text("Sample command output").font(.system(size: 13, design: .monospaced)).opacity(0.55)
                    Spacer()
                }.padding(20)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "terminal").font(.system(size: 28)).opacity(0.35)
                    Text(state.folders.isEmpty ? "Start with a project" : "A little room to think").font(.system(size: 20, weight: .medium))
                    Text(state.folders.isEmpty ? "Add a folder to begin your workspace." : "Open a terminal, or select one from the sidebar.")
                        .font(.system(size: 13)).opacity(0.6).multilineTextAlignment(.center)
                    Button(state.folders.isEmpty ? "Add folder" : "Open terminal") {
                        if let first = state.folders.first { state.addTerminal(to: first.id) } else { state.addFolder() }
                    }.buttonStyle(.bordered).padding(.top, 4)
                }.frame(maxWidth: .infinity, maxHeight: .infinity).padding(24)
            }
            Spacer(minLength: 0)
            Text("Sample session").font(.system(size: 10, design: .monospaced)).opacity(0.35).padding(16)
        }
    }
    private func sampleTerminal(_ row: SampleRow) -> some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(row.logo == "openai" ? ">_ Codex" : row.logo == "claude" ? "Claude Code" : row.title)
                .font(.system(size: 18, weight: .medium, design: .monospaced))
            Text(row.logo == "neovim" ? "# Cherry\n\nA quieter place to work.\n\n- Projects\n- Terminals\n- Commands and notes" : "~/github/cherry\n\nReady when you are.")
                .font(.system(size: 13, design: .monospaced)).lineSpacing(8).opacity(0.6)
            HStack { Text("❯"); Rectangle().frame(width: 7, height: 15) }.opacity(0.6)
            Spacer()
        }.padding(24).frame(maxWidth: .infinity, alignment: .leading)
    }
}
