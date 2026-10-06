import CherryMobileKit
import SwiftUI

/// Every Mac's sessions: what needs you first, then what works, then the
/// rest.
struct InboxView: View {
    @Environment(AppModel.self) private var model
    @Binding var path: [Route]

    var body: some View {
        List {
            let problems = model.macs.filter(\.status.isFailure)
            if !problems.isEmpty {
                Section {
                    ForEach(problems) { mac in
                        Button {
                            path.append(.macs)
                        } label: {
                            MacProblemRow(mac: mac)
                        }
                    }
                }
            }
            ForEach(Inbox.sections(of: model.sessions), id: \.section) { group in
                Section(group.section.title) {
                    ForEach(group.sessions, id: \.key) { session in
                        NavigationLink(value: Route.session(session.key)) {
                            SessionRow(session: session, macName: macName(for: session))
                        }
                    }
                }
            }
        }
        .overlay {
            if model.sessions.isEmpty {
                emptyState
            }
        }
        .refreshable { await model.refresh() }
        .navigationTitle("Cherry")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    path.append(.macs)
                } label: {
                    Label("Macs", systemImage: "desktopcomputer")
                }
            }
        }
    }

    /// The Mac's name, when sessions come from more than one Mac.
    private func macName(for session: MobileSession) -> String? {
        let connected = Set(model.sessions.map(\.macID))
        guard connected.count > 1 else { return nil }
        return model.mac(session.macID)?.endpoint.name
    }

    @ViewBuilder
    private var emptyState: some View {
        if model.macs.isEmpty {
            ContentUnavailableView {
                Label("No Macs yet", systemImage: "desktopcomputer")
            } description: {
                Text("Add a Mac to see its agents and sessions here.")
            } actions: {
                Button("Add a Mac") { path.append(.macs) }
            }
        } else if model.macs.contains(where: { $0.status == .connecting || $0.status == .idle }) {
            ProgressView("Connecting…")
        } else if !model.macs.contains(where: \.status.isFailure) {
            ContentUnavailableView("No sessions", systemImage: "terminal", description: Text("Your Macs have no Cherry sessions running."))
        }
    }
}

struct MacProblemRow: View {
    let mac: AppModel.Mac

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text(mac.endpoint.name)
                    .font(.subheadline.weight(.semibold))
                if case .failed(let reason) = mac.status {
                    Text(reason)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
    }
}

struct SessionRow: View {
    let session: MobileSession
    let macName: String?

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SessionIcon(kind: session.kind)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline) {
                    Text(heading)
                        .font(.body.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let changedAt = session.changedAt {
                        Text(changedAt, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                if let place {
                    Text(place)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                if let detail = session.detail {
                    Text(detail)
                        .font(.footnote)
                        .lineLimit(2)
                }
                AttentionBadge(attention: session.attention, isRunning: session.isRunning)
                    .padding(.top, 2)
            }
        }
        .padding(.vertical, 2)
    }

    private var heading: String {
        guard let project = session.directory.map(lastComponent), !project.isEmpty, project != "~" else {
            return session.title
        }
        return "\(session.title) · \(project)"
    }

    private var place: String? {
        let parts = [macName, session.directory].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " — ")
    }

    private func lastComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }
}

struct SessionIcon: View {
    let kind: SessionKind

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(tint.gradient)
            symbol
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: 36, height: 36)
    }

    @ViewBuilder
    private var symbol: some View {
        switch kind {
        case .agent(let name):
            Text(String(name.prefix(1)).uppercased())
                .font(.system(size: 17, weight: .bold, design: .rounded))
        case .command:
            Image(systemName: "play.fill")
        case .terminal:
            Image(systemName: "chevron.right")
        }
    }

    private var tint: Color {
        switch kind {
        case .agent(let name):
            switch name.lowercased() {
            case "claude": Color(red: 0.85, green: 0.47, blue: 0.34)
            case "codex": Color(red: 0.2, green: 0.2, blue: 0.24)
            case "pi": Color(red: 0.36, green: 0.42, blue: 0.85)
            default: Color.indigo
            }
        case .command: Color.teal
        case .terminal: Color.gray
        }
    }
}

struct AttentionBadge: View {
    let attention: AgentAttention
    let isRunning: Bool

    var body: some View {
        if let text {
            HStack(spacing: 4) {
                if attention == .working {
                    Image(systemName: "circle.dotted")
                        .symbolEffect(.rotate, options: .repeating)
                } else {
                    Circle().frame(width: 6, height: 6)
                }
                Text(text)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.14), in: Capsule())
        }
    }

    private var text: String? {
        if !isRunning { return "Ended" }
        switch attention {
        case .approval: return "Needs approval"
        case .question: return "Asks a question"
        case .resultReady: return "Result ready"
        case .working: return "Working"
        case .idle: return "Idle"
        case .error: return "Error"
        case .unknown: return nil
        }
    }

    private var color: Color {
        if !isRunning { return .secondary }
        switch attention {
        case .approval: return .orange
        case .question: return .blue
        case .resultReady: return .green
        case .working: return .purple
        case .error: return .red
        case .idle, .unknown: return .secondary
        }
    }
}
