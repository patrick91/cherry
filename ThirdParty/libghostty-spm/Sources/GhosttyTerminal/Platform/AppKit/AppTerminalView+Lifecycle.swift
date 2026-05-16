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
            core.synchronizeMetrics()
            core.requestImmediateTick()
        }

        override func layout() {
            super.layout()
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
            core.fitToSize()
        }

        internal func updateMetalLayerMetrics() {
            guard bounds.width > 0, bounds.height > 0 else { return }
            let scale = core.scaleFactor()
            metalLayer?.contentsScale = scale
            metalLayer?.drawableSize = CGSize(
                width: bounds.width * scale,
                height: bounds.height * scale
            )
        }

        internal func enforceMetalLayerScale() {
            guard let metalLayer else { return }
            let scale = core.scaleFactor()
            if metalLayer.contentsScale != scale {
                metalLayer.contentsScale = scale
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
