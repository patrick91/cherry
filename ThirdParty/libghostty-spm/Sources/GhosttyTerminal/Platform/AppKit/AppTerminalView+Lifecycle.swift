//
//  AppTerminalView+Lifecycle.swift
//  libghostty-spm
//
//  Created by Lakr233 on 2026/3/17.
//

#if canImport(AppKit) && !canImport(UIKit)
    import AppKit

    public extension AppTerminalView {
        internal func setupTrackingArea() {
            let options: NSTrackingArea.Options = [
                .mouseEnteredAndExited,
                .mouseMoved,
                .inVisibleRect,
                .activeAlways,
            ]
            let area = NSTrackingArea(
                rect: bounds,
                options: options,
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach { removeTrackingArea($0) }
            setupTrackingArea()
        }

        override var acceptsFirstResponder: Bool {
            true
        }

        override func becomeFirstResponder() -> Bool {
            let result = super.becomeFirstResponder()
            core.setFocus(true)
            return result
        }

        override func resignFirstResponder() -> Bool {
            let result = super.resignFirstResponder()
            core.setFocus(false)
            return result
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            removeWindowObservers()
            if window != nil {
                updateSurfaceVisibility()
                // SwiftUI/AppKit can temporarily detach and reattach the terminal view while
                // diffing the view hierarchy. Rebuilding on every reattach discards Ghostty's
                // scrollback/state, so only create a new surface when one does not already exist.
                if surface == nil {
                    core.rebuildIfReady()
                } else {
                    core.synchronizeMetrics()
                }
                updateMetalLayerMetrics()
                updateColorScheme()
                updateSurfaceVisibility()

                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(windowDidBecomeKey),
                    name: NSWindow.didBecomeKeyNotification,
                    object: window
                )
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(windowDidResignKey),
                    name: NSWindow.didResignKeyNotification,
                    object: window
                )
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(windowVisibilityDidChange),
                    name: NSWindow.didMiniaturizeNotification,
                    object: window
                )
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(windowVisibilityDidChange),
                    name: NSWindow.didDeminiaturizeNotification,
                    object: window
                )
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(windowVisibilityDidChange),
                    name: NSWindow.didChangeOcclusionStateNotification,
                    object: window
                )
                NotificationCenter.default.addObserver(
                    self,
                    selector: #selector(windowDidChangeScreen),
                    name: NSWindow.didChangeScreenNotification,
                    object: window
                )
                windowDidChangeScreen(Notification(
                    name: NSWindow.didChangeScreenNotification,
                    object: window
                ))
            } else {
                core.stopDisplayLink()
                core.setFocus(false)
                core.setDisplayVisible(false)
            }
        }

        @objc internal func windowDidBecomeKey(_: Notification) {
            updateSurfaceVisibility()
            let focused = window?.isKeyWindow == true
                && window?.firstResponder === self
            core.setFocus(focused)
        }

        @objc internal func windowDidResignKey(_: Notification) {
            core.setFocus(false)
            updateSurfaceVisibility()
        }

        @objc internal func windowVisibilityDidChange(_: Notification) {
            updateSurfaceVisibility()
        }

        @objc internal func windowDidChangeScreen(_: Notification) {
            guard let window else { return }
            // Keep ghostty's vsync display link on the display actually showing
            // the surface, mirroring upstream's SurfaceView.
            if let screenNumber = window.screen?.deviceDescription[
                NSDeviceDescriptionKey("NSScreenNumber")
            ] as? NSNumber {
                surface?.setDisplayID(screenNumber.uint32Value)
            }
            // AppKit does not reliably deliver viewDidChangeBackingProperties when
            // a window lands on a screen with a different scale factor
            // (ghostty-org/ghostty#2731) — re-run it once the move settles.
            DispatchQueue.main.async { [weak self] in
                self?.viewDidChangeBackingProperties()
            }
        }

        private func removeWindowObservers() {
            // Remove any existing key-window observers before registering for the
            // current window. AppKit can move the view directly between windows
            // without an intermediate nil attachment.
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didBecomeKeyNotification,
                object: nil
            )
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didResignKeyNotification,
                object: nil
            )
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didMiniaturizeNotification,
                object: nil
            )
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didDeminiaturizeNotification,
                object: nil
            )
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didChangeOcclusionStateNotification,
                object: nil
            )
            NotificationCenter.default.removeObserver(
                self,
                name: NSWindow.didChangeScreenNotification,
                object: nil
            )
        }

        private func updateSurfaceVisibility() {
            guard let window else {
                core.setDisplayVisible(false)
                return
            }

            let isRenderable = Self.isSurfaceRenderable(
                windowIsKey: window.isKeyWindow,
                isVisible: window.isVisible,
                isMiniaturized: window.isMiniaturized,
                occlusionState: window.occlusionState
            )
            core.setDisplayVisible(isRenderable)
            if isRenderable {
                core.requestImmediateTick()
            }
        }

        internal static func isSurfaceRenderable(
            windowIsKey _: Bool,
            isVisible: Bool,
            isMiniaturized: Bool,
            occlusionState: NSWindow.OcclusionState
        ) -> Bool {
            isVisible
                && !isMiniaturized
                && occlusionState.contains(.visible)
        }

        override func setFrameSize(_ newSize: NSSize) {
            super.setFrameSize(newSize)
            updateMetalLayerMetrics()
            core.synchronizeMetrics()
            core.requestImmediateTick()
        }

        override func layout() {
            super.layout()
            updateMetalLayerMetrics()
            core.synchronizeMetrics()
            core.requestImmediateTick()
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()
            updateMetalLayerMetrics()
            core.synchronizeMetrics()
            core.requestImmediateTick()
        }

        func fitToSize() {
            updateMetalLayerMetrics()
            core.fitToSize()
        }

        func drawImmediately() {
            core.drawImmediately()
        }

        internal func updateMetalLayerMetrics() {
            guard bounds.width > 0, bounds.height > 0 else { return }
            let scale = core.scaleFactor()
            // Once a surface exists, ghostty has replaced `layer` with its own
            // IOSurfaceLayer and `metalLayer` is orphaned — so the scale must be
            // applied to the *current* backing layer. IOSurfaceLayer discards any
            // rendered frame whose pixel size != bounds × contentsScale, so a stale
            // contentsScale after a screen change freezes the old-scale frame on
            // screen (looks zoomed in/out).
            guard let backingLayer = layer else { return }
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            backingLayer.contentsScale = scale
            if let metal = backingLayer as? CAMetalLayer {
                metal.drawableSize = CGSize(
                    width: bounds.width * scale,
                    height: bounds.height * scale
                )
            }
            CATransaction.commit()
        }

        internal func enforceMetalLayerScale() {
            guard let backingLayer = layer else { return }
            let scale = core.scaleFactor()
            if backingLayer.contentsScale != scale {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                backingLayer.contentsScale = scale
                CATransaction.commit()
            }
        }

        override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            updateColorScheme()
        }

        internal func updateColorScheme() {
            let scheme: TerminalColorScheme = switch effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) {
            case .darkAqua: .dark
            default: .light
            }
            surface?.setColorScheme(scheme.ghosttyValue)
            controller?.setColorScheme(scheme)
        }
    }
#endif
