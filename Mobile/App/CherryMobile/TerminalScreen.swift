import CherryMobileKit
import GhosttyTerminal
import SwiftUI
import UIKit

/// The full terminal: Ghostty's `UITerminalView` showing `cherry attach` on
/// the Mac (docs/specs/ios-app.md, Full terminal and Size).
struct TerminalScreen: View {
    @Environment(AppModel.self) private var model
    let key: SessionKey
    @State var fitsPhone: Bool
    @State private var status = TerminalStatus()

    init(key: SessionKey, fitsPhone: Bool) {
        self.key = key
        _fitsPhone = State(initialValue: fitsPhone)
    }

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Picker("Size", selection: $fitsPhone) {
                    Text("Keep Mac size").tag(false)
                    Text("Fit to phone").tag(true)
                }
                .pickerStyle(.segmented)
                Text(fitsPhone
                    ? "The session reflows to this screen while it's open here, and on the Mac too. Tap to type."
                    : "Nothing changes on the Mac. Pinch to zoom, drag to pan, tap to type.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)

            ZStack {
                if let connection = model.connection(for: key.macID), let session = model.session(key) {
                    TerminalHost(
                        connection: connection,
                        sessionID: key.sessionID,
                        mode: fitsPhone ? .fitToPhone : .keepMacSize(session.size),
                        status: status
                    )
                    .id(fitsPhone)
                } else {
                    ContentUnavailableView("Not connected", systemImage: "bolt.horizontal.circle", description: Text("This session's Mac isn't connected."))
                }
                if let message = status.message {
                    VStack {
                        Spacer()
                        Text(message)
                            .font(.footnote)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(.thinMaterial, in: Capsule())
                            .padding(.bottom, 16)
                    }
                    .allowsHitTesting(false)
                }
            }
        }
        .navigationTitle(model.session(key)?.title ?? "Terminal")
        .navigationBarTitleDisplayMode(.inline)
    }
}

/// What the terminal tells the screen about itself.
@MainActor
@Observable
final class TerminalStatus {
    var message: String? = "Attaching…"
}

struct TerminalHost: UIViewControllerRepresentable {
    let connection: any MacConnection
    let sessionID: String
    let mode: TerminalViewController.Mode
    let status: TerminalStatus

    func makeUIViewController(context: Context) -> TerminalViewController {
        TerminalViewController(connection: connection, sessionID: sessionID, mode: mode, status: status)
    }

    func updateUIViewController(_ controller: TerminalViewController, context: Context) {}

    static func dismantleUIViewController(_ controller: TerminalViewController, coordinator: ()) {
        controller.detach()
    }
}

/// Bridges a `TerminalAttachment` to a Ghostty surface: the attachment's
/// output goes into an `InMemoryTerminalSession`, what the surface types
/// goes back, in order.
///
/// Keep Mac size attaches at the session's grid: the surface is laid out
/// as large as that grid needs and shown in a zooming scroll view, and it
/// attaches only once its grid holds the session's, so nothing is drawn
/// wrapped. Fit to phone attaches at the surface's own grid and follows
/// its resizes.
@MainActor
final class TerminalViewController: UIViewController, UIScrollViewDelegate, TerminalSurfaceGridResizeDelegate,
    TerminalSurfaceTitleDelegate
{
    enum Mode: Equatable {
        case keepMacSize(TerminalSize)
        case fitToPhone
    }

    /// One Ghostty app for every terminal the app shows.
    static let terminalController = TerminalController(
        theme: TerminalTheme(light: .alabaster, dark: .afterglow)
    ) { _ in }

    private let connection: any MacConnection
    private let sessionID: String
    private let mode: Mode
    private let status: TerminalStatus

    private let terminalView = TerminalView(frame: .zero)
    private let scrollView = UIScrollView()
    private let inMemory: InMemoryTerminalSession
    private let typed: AsyncStream<Data>
    private let typedContinuation: AsyncStream<Data>.Continuation

    private var attachment: (any TerminalAttachment)?
    private var isAttaching = false
    private var isDetached = false
    private var tasks: [Task<Void, Never>] = []
    private var lastGrid: TerminalSize?

    /// The font Keep Mac size draws at, before zoom.
    private static let keepFontSize: Float = 11
    /// Fit to phone's first font (a pinch changes it, and so the grid).
    private static let fitFontSize: Float = 11

    init(connection: any MacConnection, sessionID: String, mode: Mode, status: TerminalStatus) {
        self.connection = connection
        self.sessionID = sessionID
        self.mode = mode
        self.status = status
        let (typed, continuation) = AsyncStream<Data>.makeStream()
        self.typed = typed
        typedContinuation = continuation
        inMemory = InMemoryTerminalSession(
            write: { data in continuation.yield(data) },
            resize: { _ in }
        )
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        terminalView.delegate = self
        terminalView.configuration = TerminalSurfaceOptions(
            backend: .inMemory(inMemory),
            fontSize: mode == .fitToPhone ? Self.fitFontSize : Self.keepFontSize
        )
        terminalView.controller = Self.terminalController

        switch mode {
        case .fitToPhone:
            terminalView.translatesAutoresizingMaskIntoConstraints = false
            view.addSubview(terminalView)
            NSLayoutConstraint.activate([
                terminalView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                terminalView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                terminalView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                terminalView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            ])
        case .keepMacSize:
            scrollView.translatesAutoresizingMaskIntoConstraints = false
            scrollView.delegate = self
            scrollView.maximumZoomScale = 3
            scrollView.bouncesZoom = true
            view.addSubview(scrollView)
            NSLayoutConstraint.activate([
                scrollView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
                scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
                scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
                scrollView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor),
            ])
            scrollView.addSubview(terminalView)
            // The scroll view zooms; the terminal's own pinch would change
            // its font, and so its grid.
            for recognizer in terminalView.gestureRecognizers ?? [] where recognizer is UIPinchGestureRecognizer {
                recognizer.isEnabled = false
            }
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        switch mode {
        case .fitToPhone:
            terminalView.fitToSize()
        case .keepMacSize:
            if terminalView.bounds.isEmpty {
                // A first guess; the grid's cell size corrects it.
                terminalView.frame = CGRect(origin: .zero, size: scrollView.bounds.size)
                scrollView.contentSize = terminalView.frame.size
            }
            updateZoomRange()
        }
    }

    /// Ends the attachment (`cherry attach` exits on the Mac; the session
    /// goes on).
    func detach() {
        guard !isDetached else { return }
        isDetached = true
        typedContinuation.finish()
        tasks.forEach { $0.cancel() }
        if let attachment {
            Task { await attachment.detach() }
        }
    }

    // MARK: - Ghostty's grid

    func terminalDidResize(_ size: TerminalGridMetrics) {
        let grid = TerminalSize(columns: Int(size.columns), rows: Int(size.rows))
        switch mode {
        case .fitToPhone:
            if attachment == nil {
                attach(at: grid)
            } else if grid != lastGrid, let attachment {
                Task { try? await attachment.resize(grid) }
            }
        case .keepMacSize(let target):
            if grid.columns >= target.columns, grid.rows >= target.rows {
                if attachment == nil { attach(at: target) }
            } else {
                grow(toHold: target, metrics: size)
            }
        }
        lastGrid = grid
    }

    func terminalDidChangeTitle(_ title: String) {}

    /// Lays the surface out as large as `target` needs, from the cell size
    /// Ghostty reported, with a cell to spare.
    private func grow(toHold target: TerminalSize, metrics: TerminalGridMetrics) {
        let scale = terminalView.window?.screen.scale ?? view.traitCollection.displayScale
        guard metrics.columns > 0, metrics.rows > 0, metrics.cellWidthPixels > 0, scale > 0 else { return }
        let cell = CGSize(
            width: CGFloat(metrics.cellWidthPixels) / scale,
            height: CGFloat(metrics.cellHeightPixels) / scale
        )
        let bounds = terminalView.bounds.size
        let padding = CGSize(
            width: max(0, bounds.width - CGFloat(metrics.columns) * cell.width),
            height: max(0, bounds.height - CGFloat(metrics.rows) * cell.height)
        )
        var size = CGSize(
            width: (CGFloat(target.columns + 1) * cell.width + padding.width).rounded(.up),
            height: (CGFloat(target.rows + 1) * cell.height + padding.height).rounded(.up)
        )
        // Zoomed out to the width, the surface fills the height too: rows
        // past the session's stay blank.
        let visible = scrollView.bounds.size
        if visible.width > 0 {
            let fit = min(1, visible.width / size.width)
            size.height = max(size.height, (visible.height / fit).rounded(.up))
        }
        guard size.width > bounds.width || size.height > bounds.height else { return }
        let zoom = scrollView.zoomScale
        scrollView.zoomScale = 1
        terminalView.frame = CGRect(
            origin: .zero,
            size: CGSize(width: max(size.width, bounds.width), height: max(size.height, bounds.height))
        )
        scrollView.contentSize = terminalView.frame.size
        terminalView.fitToSize()
        updateZoomRange()
        scrollView.zoomScale = max(zoom, scrollView.minimumZoomScale)
        if zoom == 1 {
            scrollView.zoomScale = scrollView.minimumZoomScale
        }
    }

    /// Zoomed out, the whole width shows.
    private func updateZoomRange() {
        guard mode != .fitToPhone, terminalView.bounds.width > 0, scrollView.bounds.width > 0 else { return }
        let fit = min(1, scrollView.bounds.width / terminalView.bounds.width)
        scrollView.minimumZoomScale = fit
        if scrollView.zoomScale < fit {
            scrollView.zoomScale = fit
        }
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? {
        terminalView
    }

    // MARK: - The attachment

    private func attach(at size: TerminalSize) {
        guard !isAttaching, !isDetached else { return }
        isAttaching = true
        status.message = "Attaching…"
        let connection = connection
        let sessionID = sessionID
        tasks.append(Task { [weak self] in
            do {
                let attachment = try await connection.attach(sessionID, size: size)
                guard let self, !self.isDetached else {
                    await attachment.detach()
                    return
                }
                self.started(attachment)
            } catch {
                self?.status.message = error.localizedDescription
            }
        })
    }

    private func started(_ attachment: any TerminalAttachment) {
        self.attachment = attachment
        status.message = nil
        let inMemory = inMemory
        tasks.append(Task { [weak self] in
            for await data in attachment.output {
                inMemory.receive(data)
            }
            guard let self, !self.isDetached else { return }
            self.status.message = "Detached: the session ended or the connection dropped."
        })
        let typed = typed
        tasks.append(Task {
            for await data in typed {
                do {
                    try await attachment.write(data)
                } catch {
                    break
                }
            }
        })
    }
}
