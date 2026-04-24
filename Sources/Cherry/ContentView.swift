import SwiftUI

struct ContentView: View {
    @ObservedObject var workspace: TerminalWorkspace

    var body: some View {
        HSplitView {
            SidebarTabsView(workspace: workspace)
                .frame(minWidth: 220, idealWidth: 248, maxWidth: 300)

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
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Ghostty Rail")
                        .font(.system(size: 19, weight: .semibold))
                    Text("Native macOS prototype")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    workspace.addSession()
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .bold))
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .background {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.08))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                }
                .help("New tab")
            }
            .padding(.horizontal, 16)
            .padding(.top, 18)
            .padding(.bottom, 16)

            Divider()

            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(workspace.sessions) { session in
                        SidebarTabRow(
                            session: session,
                            isSelected: workspace.selectedSessionID == session.id,
                            onSelect: { workspace.select(session) },
                            onClose: { workspace.close(session) }
                        )
                    }
                }
                .padding(12)
            }
        }
        .background(
            LinearGradient(
                colors: [
                    Color(nsColor: NSColor(calibratedWhite: 0.97, alpha: 1)),
                    Color(nsColor: NSColor(calibratedRed: 0.93, green: 0.95, blue: 0.98, alpha: 1))
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
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
                Circle()
                    .fill(Color(nsColor: session.tint))
                    .frame(width: 10, height: 10)

                VStack(alignment: .leading, spacing: 4) {
                    Text(session.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    Text(session.subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text(session.statusLine)
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 8)

                if isHovered || isSelected {
                    Button(role: .destructive, action: onClose) {
                        Image(systemName: "xmark")
                            .font(.system(size: 9, weight: .bold))
                            .frame(width: 16, height: 16)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(background)
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(isSelected ? Color.primary.opacity(0.10) : Color.clear, lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovered = hovering
        }
    }

    private var background: some View {
        RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(
                LinearGradient(
                    colors: isSelected
                        ? [
                            Color.white.opacity(0.96),
                            Color(nsColor: session.tint).opacity(0.14)
                        ]
                        : [
                            Color.white.opacity(isHovered ? 0.92 : 0.74),
                            Color.white.opacity(isHovered ? 0.78 : 0.58)
                        ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .shadow(color: .black.opacity(isSelected ? 0.08 : 0.03), radius: isSelected ? 14 : 8, y: 5)
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
    }
}
