import AppKit
import Combine
import SwiftUI

/// Cherry's menu bar item, made with AppKit once the launch's windows are
/// open (`CherryAppDelegate.installMenuBarItemOnceLaunchWindowsOpened`).
/// A SwiftUI `MenuBarExtra` scene makes its status item (and the item's
/// window) while the app finishes launching, whether or not it is inserted,
/// which held the first window up by 20–30 ms; a scene cannot be added
/// later. The item shows the same glyph (`MenuBarStatusLabel.icon`) and, on
/// a click, the same panel (`MenuBarAgentsPanel`) in a menu-like window
/// under it (`MenuBarPanel`), which closes when it loses key, on Escape or
/// on another click of the item.
@MainActor
final class MenuBarStatusItem: NSObject, NSWindowDelegate {
    static let shared = MenuBarStatusItem()

    private(set) var statusItem: NSStatusItem?
    private var model: MenuBarAgentsModel?
    private var panel: MenuBarPanel?
    private var subscriptions: Set<AnyCancellable> = []
    private var appearanceObservation: NSKeyValueObservation?
    private var contentSizeObservation: NSKeyValueObservation?
    private var isInstallScheduled = false

    /// Makes the item on a later main-queue turn, once.
    func installSoon() {
        guard !isInstallScheduled else { return }
        isInstallScheduled = true
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.install() }
        }
    }

    /// Makes the item now (once).
    func install() {
        guard statusItem == nil else { return }
        isInstallScheduled = true
        let model = MenuBarAgentsModel()
        self.model = model
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem = item
        if let button = item.button {
            button.setAccessibilityLabel("Cherry agents")
            button.imagePosition = .imageOnly
            button.target = self
            button.action = #selector(togglePanel(_:))
            // Opens on the press, as a menu does.
            button.sendAction(on: [.leftMouseDown, .rightMouseDown])
            appearanceObservation = button.observe(\.effectiveAppearance) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.updateIcon() }
            }
        }
        model.$aggregate
            .removeDuplicates()
            .sink { [weak self] _ in
                // After the change is stored (the publisher fires before).
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateIcon() } }
            }
            .store(in: &subscriptions)
        MenuBarShimmerModel.shared.$frame
            .removeDuplicates()
            .sink { [weak self] _ in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.updateIcon() } }
            }
            .store(in: &subscriptions)
        updateIcon()
        LaunchTimeline.mark("menu bar item installed")
    }

    private func updateIcon() {
        guard let button = statusItem?.button, let model else { return }
        let dark = button.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        let image = MenuBarStatusLabel.icon(
            for: model.aggregate,
            dark: dark,
            shimmerFrame: MenuBarShimmerModel.shared.frame,
            settings: MenuBarShimmerModel.shared.settings
        )
        if button.image !== image { button.image = image }
    }

    @objc private func togglePanel(_ sender: Any?) {
        if let panel, panel.isVisible {
            closePanel()
        } else {
            showPanel()
        }
    }

    private func showPanel() {
        guard let model, let button = statusItem?.button, let buttonWindow = button.window else { return }
        let panel = MenuBarPanel()
        panel.delegate = self
        panel.onCancel = { [weak self] in self?.closePanel() }
        // A fresh view each time: its appearance and disappearance tell the
        // background sessions list when to look (`panelDidAppear`).
        let hosting = NSHostingController(rootView: MenuBarAgentsPanel(model: model, background: .shared))
        hosting.sizingOptions = [.preferredContentSize]
        panel.setHostedContent(hosting)
        self.panel = panel
        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = buttonWindow.screen ?? NSScreen.main
        let place: @MainActor () -> Void = { [weak panel, weak hosting] in
            guard let panel, let hosting else { return }
            let size = hosting.preferredContentSize == .zero ? hosting.view.fittingSize : hosting.preferredContentSize
            panel.setFrame(
                MenuBarPanelPlacement.frame(
                    contentSize: size,
                    below: buttonRect,
                    within: screen?.visibleFrame ?? .infinite
                ),
                display: true
            )
        }
        place()
        // The panel follows its rows (the list grows to a cap, then scrolls).
        contentSizeObservation = hosting.observe(\.preferredContentSize) { _, _ in
            MainActor.assumeIsolated { place() }
        }
        button.highlight(true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func closePanel() {
        guard let panel else { return }
        self.panel = nil
        contentSizeObservation = nil
        statusItem?.button?.highlight(false)
        panel.delegate = nil
        panel.orderOut(nil)
        // Out of the window list (a key-capable window there would count as
        // a project window for a Dock click), and the view's disappearance
        // reaches the background sessions list.
        panel.removeHostedContent()
        panel.close()
    }

    func windowDidResignKey(_ notification: Notification) {
        // A click elsewhere, a row that brought a project window forward,
        // Settings… or another app.
        guard (notification.object as? MenuBarPanel) === panel else { return }
        closePanel()
    }
}

/// The window under the menu bar item: borderless, menu material and
/// rounded corners, like a `MenuBarExtra` of the window style. It takes key
/// (its rows and buttons work at once) without activating the app; Escape
/// closes it.
final class MenuBarPanel: NSPanel {
    init() {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 300, height: 120),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: true
        )
        isReleasedWhenClosed = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        hidesOnDeactivate = false
        animationBehavior = .utilityWindow
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]
    }

    /// Key only while shown: a hidden one is never taken for a window to
    /// bring forward.
    override var canBecomeKey: Bool { isVisible }
    override var canBecomeMain: Bool { false }

    /// Escape: the item closes it.
    var onCancel: (@MainActor () -> Void)?

    override func cancelOperation(_ sender: Any?) {
        MainActor.assumeIsolated { onCancel?() }
    }

    /// The controller whose view the panel shows (kept while it shows).
    private(set) var hostedController: NSViewController?

    /// `hosting`'s view over the menu material, clipped to the corners.
    func setHostedContent(_ hosting: NSViewController) {
        let background = NSVisualEffectView()
        background.material = .menu
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 10
        background.layer?.masksToBounds = true
        let view = hosting.view
        background.frame = NSRect(origin: .zero, size: view.frame.size)
        view.frame = background.bounds
        view.autoresizingMask = [.width, .height]
        background.addSubview(view)
        hostedController = hosting
        contentView = background
    }

    /// Takes the view out (its disappearance reaches SwiftUI).
    func removeHostedContent() {
        hostedController?.view.removeFromSuperview()
        hostedController = nil
        contentView = nil
    }
}

/// Where the menu bar item's panel goes: under the item's button, a gap
/// below it, centred on it, kept within the screen's visible frame.
enum MenuBarPanelPlacement {
    static let gap: CGFloat = 5

    static func frame(contentSize: NSSize, below buttonRect: NSRect, within visibleFrame: NSRect) -> NSRect {
        let width = max(contentSize.width, 1)
        let height = max(contentSize.height, 1)
        var x = buttonRect.midX - width / 2
        let y = buttonRect.minY - gap - height
        if visibleFrame != .infinite {
            x = min(max(x, visibleFrame.minX + gap), visibleFrame.maxX - gap - width)
        }
        return NSRect(x: x.rounded(), y: y.rounded(), width: width, height: height)
    }
}
