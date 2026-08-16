import Foundation
import GhosttyKit
@testable import GhosttyTerminal
import Testing
#if canImport(AppKit) && !canImport(UIKit)
    import AppKit
#endif

@MainActor
struct TerminalLifecycleTests {
    @Test
    func receiveAllowsGhosttyWriteToReenterSession() {
        let fakeSurface = ghostty_surface_t(bitPattern: 0x1)!
        var session: InMemoryTerminalSession!
        var didReenterSession = false

        session = InMemoryTerminalSession(
            write: { _ in },
            resize: { _ in },
            writeBuffer: { surface, data in
                #expect(surface == fakeSurface)
                #expect(data == Data([0x41]))
                didReenterSession = session.currentSurface == fakeSurface
            },
            processExit: { _, _, _ in }
        )
        session.setSurface(fakeSurface)

        session.receive(Data([0x41]))

        #expect(didReenterSession)
    }

    @Test
    func finishAllowsGhosttyProcessExitToReenterSession() {
        let fakeSurface = ghostty_surface_t(bitPattern: 0x2)!
        var session: InMemoryTerminalSession!
        var didReenterSession = false

        session = InMemoryTerminalSession(
            write: { _ in },
            resize: { _ in },
            writeBuffer: { _, _ in },
            processExit: { surface, exitCode, runtimeMilliseconds in
                #expect(surface == fakeSurface)
                #expect(exitCode == 7)
                #expect(runtimeMilliseconds == 123)
                didReenterSession = session.currentSurface == fakeSurface
            }
        )
        session.setSurface(fakeSurface)

        session.finish(exitCode: 7, runtimeMilliseconds: 123)

        #expect(didReenterSession)
    }

    @Test
    func failedSurfaceCreationDoesNotRetainBridge() {
        let controller = TerminalController()
        let bridge = TerminalCallbackBridge()

        let surface = controller.createSurface(
            bridge: bridge,
            configuration: .init()
        ) { _ in }

        #expect(surface == nil)
        #expect(controller.retainedBridgeCount == 0)
    }

    @Test
    func switchingControllersRemovesBridgeFromOldController() {
        let oldController = TerminalController()
        let newController = TerminalController()
        let coordinator = TerminalSurfaceCoordinator()

        coordinator.isAttached = { false }
        oldController.retain(coordinator.bridge)
        #expect(oldController.retainedBridgeCount == 1)

        coordinator.controller = oldController
        #expect(oldController.retainedBridgeCount == 0)

        oldController.retain(coordinator.bridge)
        #expect(oldController.retainedBridgeCount == 1)

        coordinator.controller = newController

        #expect(oldController.retainedBridgeCount == 0)
        #expect(newController.retainedBridgeCount == 0)
    }

    @Test
    func freeSurfaceRemovesRetainedBridge() {
        let controller = TerminalController()
        let coordinator = TerminalSurfaceCoordinator()

        coordinator.isAttached = { false }
        coordinator.controller = controller

        controller.retain(coordinator.bridge)
        #expect(controller.retainedBridgeCount == 1)

        coordinator.freeSurface()

        #expect(controller.retainedBridgeCount == 0)
    }

    @Test
    func appTerminalViewFreeSurfaceRemovesRetainedBridge() {
        let controller = TerminalController()
        let view = TerminalView(frame: .zero)

        view.controller = controller
        #expect(controller.retainedBridgeCount == 1)

        view.freeSurface()

        #expect(controller.retainedBridgeCount == 0)
    }

    @Test
    func detachedSurfaceIsReportedAsOccluded() {
        #expect(!TerminalSurfaceCoordinator.shouldReportSurfaceVisible(
            displayRequested: true,
            attached: false
        ))
        #expect(TerminalSurfaceCoordinator.shouldReportSurfaceVisible(
            displayRequested: true,
            attached: true
        ))
    }

    #if canImport(AppKit) && !canImport(UIKit)
        @Test
        func visibleNonKeyWindowCanRenderSurface() {
            #expect(AppTerminalView.isSurfaceRenderable(
                windowIsKey: false,
                isVisible: true,
                isMiniaturized: false,
                occlusionState: [.visible]
            ))
        }

        @Test
        func hiddenWindowsDoNotRenderSurface() {
            #expect(!AppTerminalView.isSurfaceRenderable(
                windowIsKey: true,
                isVisible: false,
                isMiniaturized: false,
                occlusionState: [.visible]
            ))
            #expect(!AppTerminalView.isSurfaceRenderable(
                windowIsKey: true,
                isVisible: true,
                isMiniaturized: true,
                occlusionState: [.visible]
            ))
            #expect(!AppTerminalView.isSurfaceRenderable(
                windowIsKey: true,
                isVisible: true,
                isMiniaturized: false,
                occlusionState: []
            ))
        }
    #endif
}
