import AppKit
import Foundation
import GhosttyTerminal

private final class GhosttyOutputSink: @unchecked Sendable {
    private let lock = NSLock()
    private var session: InMemoryTerminalSession

    init(session: InMemoryTerminalSession) {
        self.session = session
    }

    func setSession(_ session: InMemoryTerminalSession) {
        lock.withLock {
            self.session = session
        }
    }

    func receive(_ data: Data) {
        let session = lock.withLock {
            self.session
        }
        session.receive(data)
    }
}

private final class GhosttySessionProxy: @unchecked Sendable {
    weak var session: TerminalSession?

    init(session: TerminalSession) {
        self.session = session
    }

    func send(_ data: Data) {
        Task { @MainActor [weak self] in
            self?.session?.send(data: data)
        }
    }

    func resize(columns: Int, rows: Int) {
        Task { @MainActor [weak self] in
            self?.session?.resize(columns: columns, rows: rows)
        }
    }
}

@MainActor
final class GhosttySessionBridge: NSObject, TerminalSurfaceCloseDelegate, TerminalSurfaceBellDelegate {
    let terminalView: TerminalView

    private let proxy: GhosttySessionProxy
    private let controller: TerminalController
    private let outputSink: GhosttyOutputSink
    private var inMemorySession: InMemoryTerminalSession
    private var outputObserverID: UUID?
    private var pendingFeedActivation = false

    init(session: TerminalSession) {
        let proxy = GhosttySessionProxy(session: session)
        let inMemorySession = Self.makeInMemorySession(proxy: proxy)

        self.proxy = proxy
        self.inMemorySession = inMemorySession
        self.outputSink = GhosttyOutputSink(session: inMemorySession)
        self.controller = Self.makeController()
        self.terminalView = TerminalView(frame: .zero)

        super.init()

        terminalView.delegate = self
        terminalView.controller = controller
        terminalView.configuration = Self.makeOptions(for: session, inMemorySession: inMemorySession)
    }

    func attach(to container: NSView) {
        if terminalView.superview !== container {
            terminalView.removeFromSuperview()
            terminalView.frame = container.bounds
            terminalView.autoresizingMask = [.width, .height]
            container.addSubview(terminalView)
        }

        terminalView.frame = container.bounds
        terminalView.setSurfaceVisible(true)
        terminalView.fitToSize()
        if terminalView.window != nil {
            activateOutputFeedWhenSurfaceIsReady()
        }
    }

    func detach(from container: NSView) {
        guard terminalView.superview === container else { return }
        terminalView.setSurfaceVisible(false)
        terminalView.removeFromSuperview()
    }

    func focus(in window: NSWindow?) {
        guard let window, window.firstResponder !== terminalView else { return }
        window.makeFirstResponder(terminalView)
    }

    func reset() {
        uninstallOutputObserver()

        let nextSession = Self.makeInMemorySession(proxy: proxy)
        inMemorySession = nextSession
        outputSink.setSession(nextSession)

        if let terminalSession = proxy.session {
            terminalView.configuration = Self.makeOptions(for: terminalSession, inMemorySession: nextSession)
        }
        terminalView.fitToSize()
        activateOutputFeedWhenSurfaceIsReady()
    }

    func finish(exitCode: UInt32) {
        inMemorySession.finish(exitCode: exitCode, runtimeMilliseconds: 0)
    }

    func terminalDidClose(processAlive _: Bool) {
        proxy.session?.stop()
    }

    func terminalDidRingBell() {
        NSSound.beep()
    }

    private func activateOutputFeedWhenSurfaceIsReady() {
        guard outputObserverID == nil, !pendingFeedActivation else { return }
        pendingFeedActivation = true

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingFeedActivation = false
            self.installOutputObserver()
        }
    }

    private func installOutputObserver() {
        guard outputObserverID == nil, let session = proxy.session else { return }

        outputObserverID = session.observeRawOutput(replayExistingOutput: true) { [outputSink] data in
            outputSink.receive(data)
        }
    }

    private func uninstallOutputObserver() {
        guard let outputObserverID, let session = proxy.session else {
            self.outputObserverID = nil
            return
        }

        session.removeRawOutputObserver(id: outputObserverID)
        self.outputObserverID = nil
    }

    private static func makeInMemorySession(proxy: GhosttySessionProxy) -> InMemoryTerminalSession {
        InMemoryTerminalSession(
            write: { data in
                proxy.send(data)
            },
            resize: { viewport in
                proxy.resize(columns: Int(viewport.columns), rows: Int(viewport.rows))
            }
        )
    }

    private static func makeOptions(
        for session: TerminalSession,
        inMemorySession: InMemoryTerminalSession
    ) -> TerminalSurfaceOptions {
        TerminalSurfaceOptions(
            backend: .inMemory(inMemorySession),
            workingDirectory: session.workingDirectory,
            context: .window
        )
    }

    private static func makeController() -> TerminalController {
        TerminalController { builder in
            builder.withFontFamily("SF Mono")
            builder.withFontSize(18)
            builder.withCursorStyle(.block)
            builder.withCursorStyleBlink(true)
            builder.withBackground("121018")
            builder.withForeground("DBE3EB")
            builder.withCursorColor("92E6A7")
            builder.withSelectionBackground("3B4154")
            builder.withBackgroundOpacity(0)
            builder.withWindowPaddingX(8)
            builder.withWindowPaddingY(14)
            builder.withPalette(0, color: "3B454F")
            builder.withPalette(1, color: "EA5E5E")
            builder.withPalette(2, color: "94DE8A")
            builder.withPalette(3, color: "E8C76E")
            builder.withPalette(4, color: "73ADF2")
            builder.withPalette(5, color: "D696F2")
            builder.withPalette(6, color: "6ED1DB")
            builder.withPalette(7, color: "CAD1DB")
            builder.withPalette(8, color: "616E7A")
            builder.withPalette(9, color: "FA8280")
            builder.withPalette(10, color: "ABF29E")
            builder.withPalette(11, color: "FADE85")
            builder.withPalette(12, color: "94CCFC")
            builder.withPalette(13, color: "EBB0FC")
            builder.withPalette(14, color: "91EEF2")
            builder.withPalette(15, color: "F0F5FA")
        }
    }
}

@MainActor
final class GhosttyTerminalContainerView: NSView {
    private weak var activeSession: TerminalSession?

    override var acceptsFirstResponder: Bool {
        true
    }

    func configure(with session: TerminalSession) {
        if activeSession !== session {
            activeSession?.ghosttyBridge.detach(from: self)
            activeSession = session
            session.ghosttyBridge.attach(to: self)
        } else {
            session.ghosttyBridge.attach(to: self)
        }
    }

    override func layout() {
        super.layout()
        activeSession?.ghosttyBridge.attach(to: self)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        activeSession?.ghosttyBridge.attach(to: self)

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.activeSession?.ghosttyBridge.focus(in: self.window)
        }
    }

    override func mouseDown(with event: NSEvent) {
        if let window {
            if !window.isKeyWindow {
                window.makeKeyAndOrderFront(nil)
            }
            activeSession?.ghosttyBridge.focus(in: window)
        }
        super.mouseDown(with: event)
    }
}

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
