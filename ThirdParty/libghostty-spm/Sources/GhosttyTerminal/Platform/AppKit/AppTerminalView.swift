//
//  AppTerminalView.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/16.
//

#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
    import GhosttyKit

    @MainActor
    public final class AppTerminalView: NSView {
        let core = TerminalSurfaceCoordinator()
        var metalLayer: CAMetalLayer?
        var inputHandler: TerminalKeyEventHandler?
        var lastPerformKeyEvent: TimeInterval?
        public var onPostRender: (() -> Void)?

        public weak var delegate: (any TerminalSurfaceViewDelegate)? {
            get { core.delegate }
            set { core.delegate = newValue }
        }

        public var controller: TerminalController? {
            get { core.controller }
            set { core.controller = newValue }
        }

        public var configuration: TerminalSurfaceOptions {
            get { core.configuration }
            set { core.configuration = newValue }
        }

        public func setSurfaceVisible(_ visible: Bool) {
            core.setDisplayVisible(visible)
        }

        public func freeSurface() {
            core.freeSurface()
        }

        @discardableResult
        public func performBindingAction(_ action: String) -> Bool {
            surface?.performBindingAction(action) ?? false
        }

        /// Sends text as terminal input (→ child stdin) the way committed/typed
        /// text is. Under the native-PTY backend the host owns no PTY fd, so
        /// programmatic input must flow through the surface like this.
        public func sendText(_ text: String) {
            surface?.sendText(text)
        }

        /// Synthesizes a key press (+release). `keycode` is the AppKit virtual
        /// keycode. Used for native-PTY control/escape input (Enter, arrows, Tab,
        /// Ctrl-combos) which the text path can't express.
        public func sendKeyPress(keycode: UInt32, shift: Bool, control: Bool, option: Bool) {
            surface?.sendKeyPress(keycode: keycode, shift: shift, control: control, option: option)
        }

        /// Full scrollback as plain text (nil if unavailable). The native-PTY
        /// backend uses this to source output for hosts that own no byte stream.
        public func readScreenText() -> String? {
            surface?.readText(screen: true)
        }

        /// Visible viewport as plain text (nil if unavailable). Cheaper than
        /// `readScreenText()`; used for content-change detection.
        public func readViewportText() -> String? {
            surface?.readText(screen: false)
        }

        var surface: TerminalSurface? {
            core.surface
        }

        override public init(frame: NSRect) {
            super.init(frame: frame)
            commonInit()
        }

        @available(*, unavailable)
        required init?(coder _: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        func commonInit() {
            wantsLayer = true

            let metal = CAMetalLayer()
            metal.device = MTLCreateSystemDefaultDevice()
            metal.pixelFormat = .bgra8Unorm
            metal.framebufferOnly = true
            metal.contentsScale = NSScreen.main?.backingScaleFactor ?? 2.0
            metal.isOpaque = false
            metal.backgroundColor = NSColor.clear.cgColor
            layer = metal
            metalLayer = metal
            layer?.backgroundColor = NSColor.clear.cgColor

            inputHandler = TerminalKeyEventHandler(view: self)
            setupTrackingArea()

            core.isAttached = { [weak self] in self?.window != nil }
            core.scaleFactor = { [weak self] in
                Double(
                    self?.window?.backingScaleFactor
                        ?? NSScreen.main?.backingScaleFactor ?? 2.0
                )
            }
            core.viewSize = { [weak self] in
                guard let self else { return (0, 0) }
                return (bounds.width, bounds.height)
            }
            core.platformSetup = { [weak self] config in
                guard let self else { return }
                config.platform_tag = GHOSTTY_PLATFORM_MACOS
                config.platform = ghostty_platform_u(
                    macos: ghostty_platform_macos_s(
                        nsview: Unmanaged.passUnretained(self).toOpaque()
                    )
                )
            }
            core.onMetricsUpdate = { [weak self] in
                self?.updateMetalLayerMetrics()
            }
            core.onPostRender = { [weak self] in
                guard let self else { return }
                enforceMetalLayerScale()
                onPostRender?()
            }
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
#endif
