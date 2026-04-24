import AppKit
import SwiftUI

struct ContentView: View {
    private let minimumSidebarWidth: CGFloat = 260
    private let maximumSidebarWidth: CGFloat = 420

    @ObservedObject var workspace: TerminalWorkspace
    @State private var sidebarWidth: CGFloat = 320

    var body: some View {
        HStack(spacing: 0) {
            SidebarTabsView(workspace: workspace)
                .frame(width: sidebarWidth)
                .ignoresSafeArea(.all, edges: .top)
                .overlay(alignment: .trailing) {
                    SidebarResizeHandle(
                        sidebarWidth: $sidebarWidth,
                        minimumWidth: minimumSidebarWidth,
                        maximumWidth: maximumSidebarWidth
                    )
                    .frame(width: 4)
                    .padding(.trailing, 2)
                }

            DetailPaneView(workspace: workspace)
                .ignoresSafeArea(.all, edges: .top)
        }
        .ignoresSafeArea(.all, edges: .top)
        .background(AppShellBackground())
        .background(WindowConfigurator())
        .frame(minWidth: 1_020, minHeight: 640)
    }
}

private struct SidebarResizeHandle: NSViewRepresentable {
    @Binding var sidebarWidth: CGFloat

    let minimumWidth: CGFloat
    let maximumWidth: CGFloat

    func makeNSView(context: Context) -> SidebarResizeHandleView {
        let view = SidebarResizeHandleView()
        updateNSView(view, context: context)
        return view
    }

    func updateNSView(_ nsView: SidebarResizeHandleView, context: Context) {
        nsView.sidebarWidth = sidebarWidth
        nsView.minimumWidth = minimumWidth
        nsView.maximumWidth = maximumWidth
        nsView.onResize = { nextWidth in
            sidebarWidth = nextWidth
        }
        nsView.window?.invalidateCursorRects(for: nsView)
    }
}

private final class SidebarResizeHandleView: NSView {
    var sidebarWidth: CGFloat = 320
    var minimumWidth: CGFloat = 260
    var maximumWidth: CGFloat = 420
    var onResize: ((CGFloat) -> Void)?

    private var dragStartWidth: CGFloat?
    private var dragStartLocationX: CGFloat?

    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        dragStartWidth = sidebarWidth
        dragStartLocationX = event.locationInWindow.x
    }

    override func mouseDragged(with event: NSEvent) {
        guard let dragStartWidth, let dragStartLocationX else { return }
        let proposedWidth = dragStartWidth + event.locationInWindow.x - dragStartLocationX
        let clampedWidth = min(max(proposedWidth, minimumWidth), maximumWidth)
        sidebarWidth = clampedWidth
        onResize?(clampedWidth)
    }

    override func mouseUp(with event: NSEvent) {
        dragStartWidth = nil
        dragStartLocationX = nil
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }
}

private struct WindowConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            configure(window: view.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async {
            configure(window: nsView.window)
        }
    }

    private func configure(window: NSWindow?) {
        guard let window else { return }
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isMovableByWindowBackground = false
        window.toolbar = nil
        window.backgroundColor = NSColor(calibratedWhite: 0.82, alpha: 1)
        window.styleMask.insert(.fullSizeContentView)
    }
}

private struct DetailPaneView: View {
    @ObservedObject var workspace: TerminalWorkspace

    var body: some View {
        Group {
            if let session = workspace.selectedSession {
                TerminalSceneView(session: session)
            } else {
                ContentUnavailableView("No Active Session", systemImage: "rectangle.stack")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .strokeBorder(Color.white.opacity(0.10), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.22), radius: 18, x: 0, y: 10)
        .padding(.top, 5)
        .padding(.trailing, 5)
        .padding(.bottom, 5)
        .background(AppShellBackground())
    }
}

private struct AppShellBackground: View {
    var body: some View {
        SidebarBackground()
    }
}

private struct SidebarTabsView: View {
    @ObservedObject var workspace: TerminalWorkspace

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Sessions")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .textCase(.uppercase)
                            .padding(.horizontal, 8)

                        ForEach(workspace.sessions) { session in
                            SidebarTabRow(
                                session: session,
                                isSelected: workspace.selectedSessionID == session.id,
                                onSelect: { workspace.select(session) }
                            )
                            .contextMenu {
                                Button("Restart") {
                                    session.restart()
                                }

                                Button("Clear Scrollback") {
                                    session.clearScrollback()
                                }

                                Divider()

                                Button("Close", role: .destructive) {
                                    workspace.close(session)
                                }
                            }
                        }
                    }
                }
                .padding(.horizontal, 8)
                .padding(.top, 50)
                .padding(.bottom, 16)
            }
        }
        .background {
            SidebarBackground()
        }
    }
}

private struct SidebarBackground: View {
    var body: some View {
        Rectangle()
            .fill(.regularMaterial)
            .overlay {
                LinearGradient(
                    colors: [
                        Color.white.opacity(0.34),
                        Color(nsColor: NSColor(calibratedRed: 0.88, green: 0.93, blue: 0.94, alpha: 1)).opacity(0.34),
                        Color.white.opacity(0.18)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
    }
}

private struct SidebarTabRow: View {
    let session: TerminalSession
    let isSelected: Bool
    let onSelect: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                TerminalGlyphIcon(tint: Color(nsColor: session.tint), isSelected: isSelected)

                VStack(alignment: .leading, spacing: 3) {
                    Text(session.title)
                        .font(.system(size: 16, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 10)
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .background(background)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    @ViewBuilder
    private var background: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.76))
                .shadow(color: .black.opacity(0.04), radius: 8, y: 3)
        } else if isHovered {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.34))
        }
    }
}

private struct TerminalGlyphIcon: View {
    let tint: Color
    let isSelected: Bool

    var body: some View {
        Image(systemName: "terminal")
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(tint)
            .frame(width: 24, height: 24)
            .background {
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .strokeBorder(tint.opacity(isSelected ? 0.95 : 0.72), lineWidth: 1.5)
            }
    }
}

private struct TerminalSceneView: View {
    @ObservedObject var session: TerminalSession

    var body: some View {
        TerminalSurfaceView(session: session)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                LinearGradient(
                    colors: [
                        Color(nsColor: NSColor(calibratedRed: 0.06, green: 0.08, blue: 0.10, alpha: 1)),
                        Color(nsColor: NSColor(calibratedRed: 0.04, green: 0.05, blue: 0.07, alpha: 1))
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .ignoresSafeArea(.container, edges: .top)
    }
}
