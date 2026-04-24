import SwiftUI

struct ContentView: View {
    @ObservedObject var workspace: TerminalWorkspace

    var body: some View {
        HSplitView {
            SidebarTabsView(workspace: workspace)
                .frame(minWidth: 300, idealWidth: 320, maxWidth: 360)

            if let session = workspace.selectedSession {
                TerminalSceneView(session: session)
            } else {
                ContentUnavailableView("No Active Session", systemImage: "rectangle.stack")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color(nsColor: .windowBackgroundColor))
            }
        }
        .frame(minWidth: 1_020, minHeight: 640)
    }
}

private struct SidebarTabsView: View {
    @ObservedObject var workspace: TerminalWorkspace

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    SidebarNavigationRow(
                        title: "Live Sessions",
                        systemImage: "rectangle.stack",
                        tint: .primary,
                        isSelected: true
                    )

                    Divider()
                        .padding(.vertical, 8)

                    Button {
                        workspace.addSession()
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "plus")
                                .font(.system(size: 19, weight: .regular))
                                .frame(width: 24, height: 24)

                            Text("New Tab")
                                .font(.system(size: 16, weight: .medium))
                        }
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 9)
                    }
                    .buttonStyle(.plain)

                    ForEach(workspace.sessions) { session in
                        SidebarTabRow(
                            session: session,
                            isSelected: workspace.selectedSessionID == session.id,
                            onSelect: { workspace.select(session) },
                            onClose: { workspace.close(session) }
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
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 16)
            }
        }
        .background {
            SidebarBackground()
        }
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(Color.black.opacity(0.10))
                .frame(width: 1)
        }
    }
}

private struct SidebarNavigationRow: View {
    let title: String
    let systemImage: String
    let tint: Color
    let isSelected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 24, height: 24)

            Text(title)
                .font(.system(size: 16, weight: .semibold))

            Spacer()
        }
        .foregroundStyle(tint)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(rowBackground)
    }

    @ViewBuilder
    private var rowBackground: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(0.46))
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
    @ObservedObject var session: TerminalSession
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Image(systemName: "terminal")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color(nsColor: session.tint))
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 3) {
                    Text(session.title)
                        .font(.system(size: 16, weight: isSelected ? .semibold : .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(session.statusLine)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if isHovered || isSelected {
                    CloseTabButton(action: onClose)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
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

private struct CloseTabButton: View {
    let action: () -> Void

    var body: some View {
        Button(role: .destructive, action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 9, weight: .bold))
                .frame(width: 16, height: 16)
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help("Close tab")
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
