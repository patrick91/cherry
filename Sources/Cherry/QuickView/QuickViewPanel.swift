import AppKit
import Combine
import GhosttyTerminal
import Quartz
import SwiftUI
import UniformTypeIdentifiers

/// What a Quick View button does.
enum QuickViewAction: Hashable {
    /// This Mac's file in its app (`TerminalLinkOpening`'s rules: nothing
    /// that could run code), a folder in Finder.
    case openHere
    /// The file or folder in the default editor; another Mac's through the
    /// editor's remote support (`RemoteEditorLink`).
    case openInEditor
    case revealInFinder
    case copyPath
    /// Another Mac's file, copied to a place here the user picks.
    case saveCopy
    case reload
}

/// The buttons Quick View offers for what it shows: the first is the
/// toolbar's, the rest its More menu. Titles name the app or editor.
struct QuickViewActionList: Equatable {
    struct Item: Equatable, Hashable {
        let action: QuickViewAction
        let title: String
    }

    var primary: Item?
    var more: [Item]

    /// `appName` opens This Mac's file; `editorName` is the default editor
    /// (one with remote support for another Mac's).
    static func make(phase: QuickViewModel.Phase, machine: QuickViewMachine, appName: String?, editorName: String?) -> QuickViewActionList {
        var primary: Item?
        var more: [Item] = []
        let editor = editorName.map { Item(action: .openInEditor, title: "Open in \($0)") }
        let copyPath = Item(action: .copyPath, title: "Copy Path")
        switch (phase, machine) {
        case (.file, .thisMac):
            primary = appName.map { Item(action: .openHere, title: "Open with \($0)") }
            if let editor, editorName != appName { more.append(editor) }
            more += [Item(action: .revealInFinder, title: "Show in Finder"), copyPath]
        case (.folder, .thisMac):
            primary = Item(action: .openHere, title: "Show in Finder")
            more = [editor, copyPath].compactMap { $0 }
        case (.file, .remote), (.folder, .remote), (.tooLarge, .remote):
            primary = editor
            if case .file = phase { more.append(Item(action: .saveCopy, title: "Save a Copy…")) }
            more.append(copyPath)
        case (.looking, _):
            break
        default:
            more = [copyPath]
        }
        return QuickViewActionList(primary: primary, more: more)
    }
}

/// The Quick View window: one panel, shown again for each click, over the
/// window clicked in. It floats over Cherry's windows and hides while
/// another app is active. Escape and ⌘W close it, ⌘R reads the file again,
/// ⌘[ goes back to a folder, ⌘← and ⌘→ go through several files: the panel
/// takes them before the menu, whose ⌘W would close the tab of the window
/// behind.
final class QuickViewPanel: NSPanel {
    var onReload: (() -> Void)?
    var onBack: (() -> Void)?
    /// -1 or 1: the file before or after.
    var onStep: ((Int) -> Void)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, attachedSheet == nil {
            let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                .subtracting([.capsLock, .numericPad, .function])
            if event.keyCode == 53, modifiers.isEmpty {
                close()
                return
            }
            if modifiers == .command {
                switch event.charactersIgnoringModifiers?.lowercased() {
                case "w":
                    close()
                    return
                case "r":
                    onReload?()
                    return
                case "[":
                    onBack?()
                    return
                default:
                    break
                }
                // ← and → (the keypad's flags are not modifiers here).
                if event.keyCode == 123 || event.keyCode == 124 {
                    onStep?(event.keyCode == 123 ? -1 : 1)
                    return
                }
            }
        }
        super.sendEvent(event)
    }
}

/// Shows Quick View's panel and does its buttons.
@MainActor
final class QuickViewPanelController: NSObject, NSWindowDelegate {
    static let shared = QuickViewPanelController()

    let model = QuickViewModel()
    private(set) var panel: QuickViewPanel?
    /// The window the latest click came from: its toasts, and the panel's
    /// place when it opens.
    private weak var sourceWindow: NSWindow?

    /// Test seams.
    static var openInApp: @MainActor (URL, NSWindow?) -> Void = { url, window in
        TerminalLinkOpening.open(url.absoluteString, kind: .unknown, filesOn: nil, window: window)
    }
    static var openWithApplication: @MainActor (URL, URL) -> Void = { url, application in
        NSWorkspace.shared.open([url], withApplicationAt: application, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            if let error { SessionLog.notice("[quick-view] could not open in the editor: \(error.localizedDescription)") }
        }
    }
    static var reveal: @MainActor (URL) -> Void = { NSWorkspace.shared.activateFileViewerSelecting([$0]) }

    /// Shows `request` (its Mac's files from `source`) in the panel, over
    /// `window` when the panel was not showing.
    func show(_ request: QuickViewRequest, source: QuickViewFileSource, from window: NSWindow?) {
        show([request], source: source, from: window)
    }

    /// Shows `requests` one after another (an agent's shared files).
    /// `takesKeyboard` false (an agent opened it): it comes forward without
    /// taking the keys the user is typing elsewhere; a click on it does.
    func show(_ requests: [QuickViewRequest], source: QuickViewFileSource, from window: NSWindow?, takesKeyboard: Bool = true) {
        guard !requests.isEmpty else { return }
        sourceWindow = window
        ExternalEditorDiscovery.shared.refresh()
        let panel = panel ?? makePanel()
        let wasVisible = panel.isVisible
        model.show(requests, source: source)
        if !wasVisible {
            panel.setFrame(Self.frame(over: window?.frame ?? NSScreen.main?.visibleFrame, on: window?.screen ?? NSScreen.main), display: false)
        }
        if takesKeyboard {
            panel.makeKeyAndOrderFront(nil)
        } else {
            panel.orderFront(nil)
        }
    }

    func close() {
        panel?.close()
    }

    /// The panel's frame over `window`'s: three quarters of it, between
    /// 560×400 and 1100×820, centred, inside the screen.
    static func frame(over window: NSRect?, on screen: NSScreen?) -> NSRect {
        let area = window ?? NSRect(x: 0, y: 0, width: 1200, height: 900)
        let width = min(max(area.width * 0.75, 560), 1100)
        let height = min(max(area.height * 0.75, 400), 820)
        var frame = NSRect(x: area.midX - width / 2, y: area.midY - height / 2, width: width, height: height)
        if let visible = screen?.visibleFrame {
            frame.size.width = min(frame.width, visible.width)
            frame.size.height = min(frame.height, visible.height)
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
            frame.origin.y = min(max(frame.minY, visible.minY), visible.maxY - frame.height)
        }
        return frame.integral
    }

    private func makePanel() -> QuickViewPanel {
        let panel = QuickViewPanel(
            contentRect: NSRect(x: 0, y: 0, width: 760, height: 560),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: true
        )
        panel.title = "Quick View"
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.isReleasedWhenClosed = false
        panel.isRestorable = false
        panel.toolbarStyle = .unified
        panel.minSize = NSSize(width: 420, height: 300)
        panel.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        panel.onReload = { [weak self] in self?.model.reload() }
        panel.onBack = { [weak self] in self?.model.goBack() }
        panel.onStep = { [weak self] offset in self?.model.showItem(offset: offset) }
        let content = QuickViewContent(
            model: model,
            actions: { [weak self] in self?.actions ?? QuickViewActionList(primary: nil, more: []) },
            perform: { [weak self] action in self?.perform(action) }
        )
        let hosting = NSHostingController(rootView: content)
        hosting.sizingOptions = []
        hosting.sceneBridgingOptions = [.toolbars, .title]
        panel.contentViewController = hosting
        panel.delegate = self
        self.panel = panel
        return panel
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        MainActor.assumeIsolated { model.stop() }
    }

    // MARK: Buttons

    /// The buttons for what the panel shows now.
    var actions: QuickViewActionList {
        QuickViewActionList.make(
            phase: model.phase, machine: model.machine, appName: appName(), editorName: editor()?.displayName
        )
    }

    /// The app This Mac's shown file opens in.
    private func appName() -> String? {
        guard let document = model.document, !document.machine.isRemote else { return nil }
        return NSWorkspace.shared.urlForApplication(toOpen: document.fileURL)
            .map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
    }

    /// The default editor (Settings › Projects), one that opens another
    /// Mac's files over SSH for theirs.
    private func editor() -> InstalledEditor? {
        var editors = ExternalEditorDiscovery.shared.installedEditors
        if model.machine.isRemote { editors = editors.filter(RemoteEditorLink.supports) }
        return ExternalEditorDiscovery.resolveDefault(editors: editors, preferredID: TerminalSettings.shared.defaultEditorID)
    }

    func perform(_ action: QuickViewAction) {
        let path = model.shownPath
        switch action {
        case .reload:
            model.reload()
        case .copyPath:
            guard let path else { return }
            let pasteboard = TerminalClipboard.pasteboard()
            pasteboard.clearContents()
            pasteboard.setString(path, forType: .string)
        case .openHere:
            guard let path, !model.machine.isRemote else { return }
            if case .folder = model.phase {
                Self.openInApp(URL(fileURLWithPath: path, isDirectory: true), sourceWindow)
            } else if let document = model.document {
                Self.openInApp(document.fileURL, sourceWindow)
            }
        case .revealInFinder:
            guard let document = model.document, !document.machine.isRemote else { return }
            Self.reveal(document.fileURL)
        case .openInEditor:
            guard let path, let editor = editor() else { return }
            switch model.machine {
            case .thisMac:
                Self.openWithApplication(URL(fileURLWithPath: path), editor.appURL)
            case let .remote(_, destination):
                guard let link = RemoteEditorLink.url(editor: editor, destination: destination, path: path) else { return }
                Self.openWithApplication(link, editor.appURL)
            }
        case .saveCopy:
            guard let document = model.document, let panel else { return }
            let save = NSSavePanel()
            save.nameFieldStringValue = document.name
            save.message = "Save a copy of \(document.name) from \(document.machine.name) on this Mac."
            save.beginSheetModal(for: panel) { response in
                guard response == .OK, let destination = save.url else { return }
                do {
                    if FileManager.default.fileExists(atPath: destination.path) {
                        _ = try FileManager.default.replaceItemAt(destination, withItemAt: Self.temporaryCopy(of: document.fileURL))
                    } else {
                        try FileManager.default.copyItem(at: document.fileURL, to: destination)
                    }
                } catch {
                    NSAlert(error: error).beginSheetModal(for: panel)
                }
            }
        }
    }

    /// A copy of `url` next to the temporary items, for `replaceItemAt`
    /// (which moves it into place).
    private nonisolated static func temporaryCopy(of url: URL) throws -> URL {
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + "-" + url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: copy)
        return copy
    }
}

// MARK: - The panel's content

struct QuickViewContent: View {
    @ObservedObject var model: QuickViewModel
    /// The buttons for what it shows (`QuickViewPanelController.actions`).
    let actions: @MainActor () -> QuickViewActionList
    let perform: @MainActor (QuickViewAction) -> Void

    var body: some View {
        content
            .frame(minWidth: 420, maxWidth: .infinity, minHeight: 260, maxHeight: .infinity)
            .navigationTitle(model.title)
            .navigationSubtitle(subtitle)
            .toolbar { toolbar }
    }

    /// Where it is: which of several files, its folder, and the Mac when
    /// it is another.
    private var subtitle: String {
        let place = placeText
        guard model.items.count > 1 else { return place }
        let position = "\(model.itemIndex + 1) of \(model.items.count)"
        return place.isEmpty ? position : "\(position) · \(place)"
    }

    private var placeText: String {
        guard let path = model.shownPath, path.hasPrefix("/") || path.hasPrefix("~") else {
            return model.machine.isRemote ? model.machine.name : ""
        }
        var folder = (path as NSString).deletingLastPathComponent
        if !model.machine.isRemote {
            let home = NSHomeDirectory()
            if folder == home { folder = "~" } else if folder.hasPrefix(home + "/") { folder = "~" + folder.dropFirst(home.count) }
        }
        return model.machine.isRemote ? "\(folder) · \(model.machine.name)" : folder
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem(placement: .navigation) {
            Button {
                model.goBack()
            } label: {
                Label("Back", systemImage: "chevron.left")
            }
            .disabled(!model.canGoBack)
            .help("Back to the folder (⌘[)")
        }
        if model.items.count > 1 {
            ToolbarItem(placement: .navigation) {
                ControlGroup {
                    Button {
                        model.showItem(offset: -1)
                    } label: {
                        Label("Previous File", systemImage: "chevron.up")
                    }
                    .disabled(!model.canShowPrevious)
                    .help("Previous file (⌘←)")
                    Button {
                        model.showItem(offset: 1)
                    } label: {
                        Label("Next File", systemImage: "chevron.down")
                    }
                    .disabled(!model.canShowNext)
                    .help("Next file (⌘→)")
                }
            }
        }
        ToolbarItemGroup(placement: .primaryAction) {
            let actions = actions()
            if let primary = actions.primary {
                Button(primary.title) { perform(primary.action) }
            }
            Button {
                perform(.reload)
            } label: {
                Label("Reload", systemImage: "arrow.clockwise")
            }
            .help(model.machine.isRemote ? "Copy it again from \(model.machine.name) (⌘R)" : "Read it again (⌘R)")
            .disabled(isLooking)
            Menu {
                ForEach(actions.more, id: \.self) { item in
                    Button(item.title) { perform(item.action) }
                }
            } label: {
                Label("More", systemImage: "ellipsis.circle")
            }
            .disabled(actions.more.isEmpty)
        }
    }

    private var isLooking: Bool {
        switch model.phase {
        case .looking, .copying: true
        default: false
        }
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case let .looking(link):
            progress(model.machine.isRemote ? "Looking for \(link) on \(model.machine.name)…" : "Looking for \(link)…")
        case let .copying(file):
            progress("Copying \(file.name) from \(model.machine.name)…", detail: file.size.map(Self.byteText))
        case let .file(document):
            switch document.presentation {
            case let .text(text, isTruncated):
                QuickViewTextView(text: text, line: document.line, path: document.path, revision: document.revision)
                    .overlay(alignment: .bottom) {
                        if isTruncated {
                            note("Showing the first \(Self.byteText(Int64(QuickViewDocument.maximumTextBytes))) of \(document.size.map(Self.byteText) ?? "the file").")
                        }
                    }
            case .quickLook:
                QuickLookPreview(url: document.fileURL, revision: document.revision)
            }
        case let .folder(folder):
            QuickViewFolderList(folder: folder, machine: model.machine) { model.open($0) }
        case let .missing(request):
            ContentUnavailableView {
                Label("No file at \(request.linkText)", systemImage: "doc.questionmark")
            } description: {
                Text(missingDescription(request))
            }
        case let .special(path):
            ContentUnavailableView(
                "\((path as NSString).lastPathComponent) is no file or folder",
                systemImage: "questionmark.square.dashed",
                description: Text("Quick View shows files and folders.")
            )
        case let .tooLarge(file, size):
            ContentUnavailableView(
                "\(file.name) is too large to preview",
                systemImage: "externaldrive",
                description: Text("It is \(Self.byteText(size)); Quick View copies files of up to \(Self.byteText(QuickViewRemoteFiles.maximumCopyBytes)) from \(model.machine.name).")
            )
        case let .unreadable(file):
            ContentUnavailableView(
                "Cherry can’t read \(file.name)",
                systemImage: "lock.doc",
                description: Text("You don’t have permission to read it on \(model.machine.name).")
            )
        case let .failed(message):
            ContentUnavailableView {
                Label("Couldn’t show this", systemImage: "exclamationmark.triangle")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { perform(.reload) }
            }
        }
    }

    private func missingDescription(_ request: QuickViewRequest) -> String {
        let paths = request.candidates.map(\.path)
        let place = model.machine.isRemote ? "on \(model.machine.name)" : "on this Mac"
        if paths.count == 1 { return "Nothing is at \(paths[0]) \(place)." }
        return "Cherry looked \(place) at:\n" + paths.joined(separator: "\n")
    }

    private func progress(_ text: String, detail: String? = nil) -> some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(text)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(.regularMaterial, in: Capsule())
            .padding(.bottom, 10)
    }

    static func byteText(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// A folder's entries; a double-click or Return goes into one.
struct QuickViewFolderList: View {
    let folder: QuickViewFolder
    let machine: QuickViewMachine
    let open: (QuickViewFolder.Entry) -> Void
    @State private var selection: QuickViewFolder.Entry.ID?

    var body: some View {
        if !folder.isReadable {
            ContentUnavailableView(
                "Cherry can’t list \(folder.name)",
                systemImage: "lock",
                description: Text("You don’t have permission to read it on \(machine.name).")
            )
        } else if folder.entries.isEmpty {
            ContentUnavailableView("\(folder.name) is empty", systemImage: "folder")
        } else {
            List(folder.entries, selection: $selection) { entry in
                Label {
                    Text(entry.name)
                } icon: {
                    Image(nsImage: Self.icon(for: entry))
                        .resizable()
                        .frame(width: 16, height: 16)
                }
                .tag(entry.id)
            }
            .contextMenu(forSelectionType: QuickViewFolder.Entry.ID.self) { _ in
                EmptyView()
            } primaryAction: { ids in
                guard let id = ids.first, let entry = folder.entries.first(where: { $0.id == id }) else { return }
                open(entry)
            }
            .overlay(alignment: .bottom) {
                if folder.isTruncated {
                    Text("Showing the first \(folder.entries.count) entries.")
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.regularMaterial, in: Capsule())
                        .padding(.bottom, 10)
                }
            }
        }
    }

    static func icon(for entry: QuickViewFolder.Entry) -> NSImage {
        if entry.isFolder { return NSWorkspace.shared.icon(for: .folder) }
        let type = UTType(filenameExtension: (entry.name as NSString).pathExtension) ?? .data
        return NSWorkspace.shared.icon(for: type)
    }
}

/// Quick Look's preview of a file here; read again when `revision` changes.
struct QuickLookPreview: NSViewRepresentable {
    let url: URL
    let revision: Int

    final class Coordinator {
        var url: URL?
        var revision = 0
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> QLPreviewView {
        let view = QLPreviewView(frame: .zero, style: .normal) ?? QLPreviewView()
        view.autostarts = true
        // The panel is reused: the view closes when SwiftUI removes it.
        view.shouldCloseWithWindow = false
        view.previewItem = url as NSURL
        context.coordinator.url = url
        context.coordinator.revision = revision
        return view
    }

    func updateNSView(_ view: QLPreviewView, context: Context) {
        if context.coordinator.url != url {
            view.previewItem = url as NSURL
        } else if context.coordinator.revision != revision {
            view.refreshPreviewItem()
        }
        context.coordinator.url = url
        context.coordinator.revision = revision
    }

    static func dismantleNSView(_ view: QLPreviewView, coordinator: Coordinator) {
        view.close()
    }
}

/// Text Cherry shows itself: monospaced, selectable, searchable (⌘F), at
/// the link's line, which is selected. Shown again after a change (the
/// same file and line), it keeps its place.
struct QuickViewTextView: NSViewRepresentable {
    let text: String
    let line: Int?
    let path: String
    let revision: Int

    final class Coordinator {
        var path: String?
        var line: Int?
        var revision = 0
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = true
        if let textView = scrollView.documentView as? NSTextView {
            textView.isEditable = false
            textView.isSelectable = true
            textView.isRichText = false
            textView.importsGraphics = false
            textView.usesFindBar = true
            textView.isIncrementalSearchingEnabled = true
            textView.isAutomaticLinkDetectionEnabled = false
            textView.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            textView.textContainerInset = NSSize(width: 10, height: 10)
        }
        show(in: scrollView, context: context, keepingPlace: false)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        let samePlace = context.coordinator.path == path && context.coordinator.line == line
        guard !samePlace || context.coordinator.revision != revision else { return }
        show(in: scrollView, context: context, keepingPlace: samePlace)
    }

    private func show(in scrollView: NSScrollView, context: Context, keepingPlace: Bool) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        let origin = scrollView.contentView.bounds.origin
        textView.string = text
        context.coordinator.path = path
        context.coordinator.line = line
        context.coordinator.revision = revision
        if keepingPlace {
            scrollView.contentView.scroll(to: origin)
            scrollView.reflectScrolledClipView(scrollView.contentView)
            return
        }
        let range = line.flatMap { QuickViewDocument.range(ofLine: $0, in: text) }
        DispatchQueue.main.async {
            textView.window?.makeFirstResponder(textView)
            guard let range else {
                textView.scrollRangeToVisible(NSRange(location: 0, length: 0))
                return
            }
            textView.setSelectedRange(range)
            textView.scrollRangeToVisible(range)
            textView.showFindIndicator(for: range)
        }
    }
}
