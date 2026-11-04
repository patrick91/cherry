import CherryMobileKit
import SwiftUI

/// Every Mac's sessions by project: a heading per project, its agents a
/// line each with what they need, its commands and terminals under them;
/// the projects whose agents wait on you first, quiet ones folded at the
/// end. Filters keep the agents that need you, or those that work.
struct InboxView: View {
    @Environment(AppModel.self) private var model
    @Binding var path: [Route]
    @State private var filter: InboxFilter = .all
    /// The quiet projects opened to show their sessions.
    @State private var openQuiet: Set<String> = []

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                problems
                if !model.sessions.isEmpty {
                    filters
                }
                let projects = Inbox.projects(of: model.sessions, filter: filter)
                ForEach(projects.filter { filter != .all || !$0.isQuiet }) { project in
                    ProjectSection(project: project, place: place(of: project, among: projects))
                }
                let quiet = filter == .all ? projects.filter(\.isQuiet) : []
                if !quiet.isEmpty {
                    quietProjects(quiet, among: projects)
                }
                if filter != .all, projects.isEmpty {
                    Text(filter == .needsYou ? "Nothing needs you." : "No agent is working.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.top, 48)
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 24)
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

    @ViewBuilder
    private var problems: some View {
        let problems = model.macs.filter { $0.status.isFailure || $0.status.isReconnecting }
        ForEach(problems) { mac in
            Button {
                path.append(.macs)
            } label: {
                MacProblemRow(mac: mac)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain)
            .padding(.top, 8)
        }
    }

    private var filters: some View {
        HStack(spacing: 8) {
            FilterChip(title: "All", isOn: filter == .all) { filter = .all }
            FilterChip(title: title(of: .needsYou, "Needs you"), isOn: filter == .needsYou) { filter = .needsYou }
            FilterChip(title: title(of: .working, "Working"), isOn: filter == .working) { filter = .working }
        }
        .padding(.top, 6)
    }

    private func title(of filter: InboxFilter, _ name: String) -> String {
        let count = Inbox.count(filter, in: model.sessions)
        return count == 0 ? name : "\(name) · \(count)"
    }

    private func quietProjects(_ quiet: [InboxProject], among projects: [InboxProject]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Quiet")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 2)
            ForEach(quiet) { project in
                let isOpen = openQuiet.contains(project.id)
                Button {
                    withAnimation(.snappy) {
                        if isOpen { openQuiet.remove(project.id) } else { openQuiet.insert(project.id) }
                    }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(project.name)
                            .font(.body.weight(.semibold))
                        Text(summary(of: project, among: projects))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                    }
                    .padding(.vertical, 11)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                if isOpen {
                    SessionLines(project: project)
                        .padding(.bottom, 6)
                }
                Divider()
            }
        }
        .padding(.top, 28)
    }

    /// A quiet project's Mac (with several), then its sessions' names.
    private func summary(of project: InboxProject, among projects: [InboxProject]) -> String {
        let names = project.agents.map { $0.task ?? $0.agentDisplayName ?? $0.title } + project.others.map(\.title)
        return ([place(of: project, among: projects)].compactMap { $0 } + names).joined(separator: " · ")
    }

    /// What tells a project from another of its name: its Mac, when
    /// sessions come from several, and its folder's place, when another
    /// project of its Mac has its name.
    private func place(of project: InboxProject, among projects: [InboxProject]) -> String? {
        var parts: [String] = []
        if Set(model.sessions.map(\.macID)).count > 1, let mac = model.mac(project.macID) {
            parts.append(mac.endpoint.name)
        }
        if projects.contains(where: { $0.id != project.id && $0.macID == project.macID && $0.name == project.name }) {
            parts.append(project.parent)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
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
        } else if model.macs.contains(where: { $0.status == .connecting || $0.status == .idle || $0.status.isReconnecting }) {
            ProgressView("Connecting…")
        } else if !model.macs.contains(where: \.status.isFailure) {
            ContentUnavailableView("No sessions", systemImage: "terminal", description: Text("Your Macs have no Cherry sessions running."))
        }
    }
}

struct FilterChip: View {
    let title: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(isOn ? .semibold : .medium))
                .foregroundStyle(isOn ? Color(.systemBackground) : Color.primary)
                .padding(.horizontal, 14)
                .frame(minHeight: 34)
                .background(isOn ? Color.primary : Color(.tertiarySystemFill), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}

/// A project: its name as a heading (with what tells it from another of
/// its name), then its sessions.
struct ProjectSection: View {
    let project: InboxProject
    let place: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(project.name)
                    .font(.title2.weight(.bold))
                    .lineLimit(1)
                Spacer(minLength: 8)
                if let place {
                    Text(place)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.head)
                }
            }
            .padding(.bottom, 2)
            .accessibilityAddTraits(.isHeader)
            SessionLines(project: project)
        }
        .padding(.top, 20)
    }
}

/// A project's agents, divided, then its commands and terminals.
struct SessionLines: View {
    let project: InboxProject

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(project.agents.enumerated()), id: \.element.key) { index, session in
                NavigationLink(value: Route.session(session.key)) {
                    AgentLine(session: session)
                }
                .buttonStyle(.plain)
                if index < project.agents.count - 1 || !project.others.isEmpty {
                    Divider()
                        .padding(.leading, 26)
                }
            }
            ForEach(project.others, id: \.key) { session in
                NavigationLink(value: Route.session(session.key)) {
                    ProgramLine(session: session)
                }
                .buttonStyle(.plain)
            }
        }
    }
}

/// An agent: what it needs, its task (else its name) and when that began,
/// then the agent and what it says.
struct AgentLine: View {
    let session: MobileSession

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            StatusMark(session: session)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(session.task ?? session.agentDisplayName ?? session.title)
                        .font(.body.weight(.medium))
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    if let changedAt = session.changedAt {
                        Text(changedAt, format: .relative(presentation: .numeric, unitsStyle: .narrow))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                if let line {
                    line
                        .font(.subheadline)
                        .lineLimit(2)
                }
            }
        }
        .padding(.vertical, 10)
        .contentShape(Rectangle())
    }

    /// "Claude · Approve Bash: npm test", what it says in the colour of
    /// what it needs; the agent alone when its name is the line's title.
    private var line: Text? {
        let says = session.isRunning ? session.detail ?? Self.state(of: session.attention) : "Ended"
        let agent = session.task == nil ? nil : session.agentDisplayName
        switch (agent, says) {
        case (let agent?, let says?):
            return Text("\(Text(agent).foregroundStyle(.secondary))\(Text(" · ").foregroundStyle(.secondary))\(Text(says).foregroundStyle(color))")
        case (let agent?, nil):
            return Text(agent).foregroundStyle(.secondary)
        case (nil, let says?):
            return Text(says).foregroundStyle(color)
        case (nil, nil):
            return nil
        }
    }

    private var color: Color {
        session.isRunning ? Color.attention(session.attention) : .secondary
    }

    private static func state(of attention: AgentAttention) -> String? {
        switch attention {
        case .approval: "Needs approval"
        case .question: "Asks a question"
        case .error: "Failed"
        case .resultReady: "Result ready"
        case .working: "Working"
        case .idle: "Idle"
        case .unknown: nil
        }
    }
}

/// A command or terminal: its name in the terminal's type, small.
struct ProgramLine: View {
    let session: MobileSession

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Group {
                if session.kind == .command {
                    Image(systemName: "play.fill")
                        .font(.system(size: 9))
                } else {
                    Text("›_")
                        .font(.system(size: 12, weight: .semibold, design: .monospaced))
                }
            }
            .foregroundStyle(.tertiary)
            .frame(width: 14)
            Text(session.title)
                .font(.system(.subheadline, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if !session.isRunning {
                Text("ended")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 9)
        .contentShape(Rectangle())
        .accessibilityLabel("\(session.kind == .command ? "Command" : "Terminal") \(session.title)\(session.isRunning ? "" : ", ended")")
    }
}

/// What an agent needs, at the start of its line: a dot for an approval
/// or a question, a check for a result, a spinner while it works, nothing
/// when idle.
struct StatusMark: View {
    let session: MobileSession

    var body: some View {
        mark
            .frame(width: 14, height: 22)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private var mark: some View {
        if session.isRunning {
            switch session.attention {
            case .approval:
                Circle()
                    .fill(.orange)
                    .frame(width: 10, height: 10)
            case .question:
                Circle()
                    .fill(.blue)
                    .frame(width: 10, height: 10)
            case .error:
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.attention(.error))
            case .resultReady:
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.attention(.resultReady))
            case .working:
                ProgressView()
                    .controlSize(.mini)
                    .tint(.purple)
            case .idle, .unknown:
                EmptyView()
            }
        }
    }
}

extension Color {
    /// What an agent needs, as text that reads on the background: darker
    /// in light mode than the system colours, which are made for fills.
    static func attention(_ attention: AgentAttention) -> Color {
        func adaptive(light: UIColor, dark: UIColor) -> Color {
            Color(UIColor { $0.userInterfaceStyle == .dark ? dark : light })
        }
        return switch attention {
        case .approval: adaptive(light: UIColor(red: 0.64, green: 0.31, blue: 0, alpha: 1), dark: .systemOrange)
        case .question: adaptive(light: UIColor(red: 0.04, green: 0.36, blue: 0.77, alpha: 1), dark: .systemBlue)
        case .error: adaptive(light: UIColor(red: 0.75, green: 0.13, blue: 0.11, alpha: 1), dark: .systemRed)
        case .resultReady: adaptive(light: UIColor(red: 0.11, green: 0.48, blue: 0.22, alpha: 1), dark: .systemGreen)
        case .working, .idle, .unknown: .secondary
        }
    }
}

struct MacProblemRow: View {
    let mac: AppModel.Mac

    private var reason: String? {
        switch mac.status {
        case .failed(let reason), .reconnecting(let reason): reason
        default: nil
        }
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if mac.status.isReconnecting {
                ProgressView()
                    .controlSize(.small)
            } else {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(mac.status.isReconnecting ? "Reconnecting to \(mac.endpoint.name)…" : mac.endpoint.name)
                    .font(.subheadline.weight(.semibold))
                if let reason {
                    Text(reason)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            // Reconnecting is no error: not in the button's tint.
            .foregroundStyle(mac.status.isReconnecting ? AnyShapeStyle(Color.primary) : AnyShapeStyle(.tint))
        }
    }
}
