import Foundation
import GhosttyKit
@testable import GhosttyTerminal
import Testing

#if canImport(AppKit) && !canImport(UIKit)
    import AppKit

    /// Moving a window between screens with different backing scale factors
    /// must propagate the new scale to the layer ghostty actually renders
    /// into. Ghostty replaces the view's backing layer with its own
    /// IOSurfaceLayer at surface creation, and that layer discards any frame
    /// whose pixel size != bounds × contentsScale — so a stale contentsScale
    /// freezes the old-scale frame on screen (looks zoomed in/out).
    @MainActor
    struct TerminalBackingScaleTests {
        private func makeAttachedView(
            scale: @escaping () -> Double
        ) async throws -> (AppTerminalView, NSWindow) {
            let view = AppTerminalView(frame: NSRect(x: 0, y: 0, width: 640, height: 400))
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 640, height: 400),
                styleMask: [.borderless],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.contentView = view
            window.orderFrontRegardless()

            view.core.scaleFactor = scale
            let session = InMemoryTerminalSession(
                write: { _ in },
                resize: { _ in },
                writeBuffer: { _, _ in },
                processExit: { _, _, _ in }
            )
            view.configuration = TerminalSurfaceOptions(backend: .inMemory(session))
            view.controller = TerminalController()
            try await Task.sleep(for: .milliseconds(50))
            view.drawImmediately()
            try await Task.sleep(for: .milliseconds(50))
            return (view, window)
        }

        @Test
        func backingPropertyChangePropagatesScaleToLiveBackingLayer() async throws {
            var scale = 2.0
            let (view, window) = try await makeAttachedView { scale }
            defer {
                view.freeSurface()
                window.close()
            }

            #expect(view.surface != nil)
            #expect(view.layer?.contentsScale == 2.0)

            scale = 1.0
            view.viewDidChangeBackingProperties()

            #expect(view.layer?.contentsScale == 1.0)
            let size = view.surface?.size()
            #expect(size?.widthPixels == 640)
            #expect(size?.heightPixels == 400)
        }

        @Test
        func screenChangeWithoutBackingCallbackStillPropagatesScale() async throws {
            var scale = 2.0
            let (view, window) = try await makeAttachedView { scale }
            defer {
                view.freeSurface()
                window.close()
            }

            // AppKit does not reliably send viewDidChangeBackingProperties on a
            // screen move (ghostty-org/ghostty#2731); the screen-change observer
            // must re-run it.
            scale = 1.0
            NotificationCenter.default.post(
                name: NSWindow.didChangeScreenNotification,
                object: window
            )
            try await Task.sleep(for: .milliseconds(50))

            #expect(view.layer?.contentsScale == 1.0)
        }
    }
#endif
