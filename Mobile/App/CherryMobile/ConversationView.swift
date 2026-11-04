import CherryMobileKit
import SwiftUI

/// An agent's conversation, read from its own session on the Mac (`cherry
/// host transcript`): the latest messages and tool calls, then what comes
/// after them every few seconds, kept to the bottom, and a menu its screen
/// asks with under them.
struct ConversationView: View {
    @Environment(AppModel.self) private var model
    let key: SessionKey
    /// The session's folder, which tool calls' paths are shown relative to.
    let project: String?
    /// What the agent says it is working on, while it works: a row under
    /// the last entry says so.
    let working: String?
    /// Why the Mac's connection is away, shown over the last conversation.
    let reconnecting: String?
    /// The menu the agent's screen shows (a permission prompt, a question),
    /// answered in place.
    let question: ScreenMenu?
    let answer: @MainActor ([MobileKey]) async -> Void
    let showScreen: () -> Void

    @State private var conversation = Conversation()
    @State private var problem: MacConnectionError?
    @State private var loaded = false

    /// Entries a first read asks for.
    private static let limit = 150

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 14) {
                if conversation.moreBefore {
                    Text("Earlier messages aren't shown.")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity)
                }
                ForEach(ConversationRow.rows(of: conversation.entries)) { row in
                    switch row {
                    case .entry(let entry):
                        MessageView(entry: entry)
                    case .tools(let tools):
                        ToolGroupView(tools: tools, project: project)
                    }
                }
                if let question {
                    QuestionCard(menu: question, answer: answer)
                        // A new question starts unanswered.
                        .id([question.question ?? ""] + question.options.map(\.label))
                } else if let working, loaded {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text(working.isEmpty ? "Working…" : "Working · \(working)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                    .padding(.leading, 4)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .overlay { emptyState }
        .overlay(alignment: .bottom) {
            if let note = reconnecting ?? (loaded && (!conversation.entries.isEmpty || question != nil) ? problem?.localizedDescription : nil) {
                Label(note, systemImage: reconnecting == nil ? "exclamationmark.triangle.fill" : "arrow.triangle.2.circlepath")
                    .font(.footnote)
                    .padding(10)
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                    .padding()
            }
        }
        // Again on a new connection (the Mac reconnected).
        .task(id: model.connection(for: key.macID).map(ObjectIdentifier.init)) {
            await follow()
        }
    }

    /// None under a question, which shows still.
    @ViewBuilder
    private var emptyState: some View {
        if question != nil {
            EmptyView()
        } else if let problem, conversation.entries.isEmpty {
            ContentUnavailableView {
                Label("No conversation", systemImage: "text.bubble")
            } description: {
                Text(problem.localizedDescription)
            } actions: {
                Button("Show the Screen", action: showScreen)
            }
        } else if !loaded, reconnecting == nil {
            ProgressView()
        } else if loaded, conversation.entries.isEmpty {
            ContentUnavailableView("No messages yet", systemImage: "text.bubble", description: Text("The agent hasn't written anything in this session yet."))
        }
    }

    /// Reads what is new until the view goes away: every 2 s, every 5 s for
    /// Amp, whose conversation comes from its server.
    private func follow() async {
        guard model.connection(for: key.macID) != nil else { return }
        while !Task.isCancelled {
            await load()
            let interval: Duration = conversation.agent == "amp" ? .seconds(5) : .seconds(2)
            try? await Task.sleep(for: interval)
        }
    }

    private func load() async {
        do {
            let read = try await model.transcript(of: key, after: conversation.cursor, limit: Self.limit)
            conversation.apply(read)
            problem = nil
        } catch let error as MacConnectionError {
            // The Mac reconnecting says so already.
            if case .unreachable = error { return }
            problem = error
        } catch {
            problem = .failed(error.localizedDescription)
        }
        loaded = true
    }
}

/// A menu the agent asks with, in the conversation: its question, then each
/// option with what describes it. An option types its digit, which an agent
/// takes by itself; the others wait until the screen changes.
struct QuestionCard: View {
    let menu: ScreenMenu
    let answer: @MainActor ([MobileKey]) async -> Void
    @State private var chosen: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label {
                Text(menu.question ?? "Choose an option")
                    .font(.subheadline.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "questionmark.bubble.fill")
                    .foregroundStyle(Color.accentColor)
            }
            VStack(spacing: 6) {
                ForEach(menu.options, id: \.number) { option in
                    optionButton(option)
                }
            }
        }
        .padding(12)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Color.accentColor.opacity(0.3)))
    }

    private func optionButton(_ option: ScreenMenu.Option) -> some View {
        Button {
            choose(option)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Text("\(option.number)")
                    .font(.caption.monospacedDigit().weight(.bold))
                    .frame(width: 22, height: 22)
                    .background(option.isSelected ? Color.accentColor : Color.secondary.opacity(0.22), in: Circle())
                    .foregroundStyle(option.isSelected ? Color.white : Color.primary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label)
                        .font(.subheadline)
                    if let detail = option.detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                if chosen == option.number {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 10))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(chosen != nil)
        .opacity(chosen == nil || chosen == option.number ? 1 : 0.45)
        .accessibilityLabel("Option \(option.number): \(option.label)")
    }

    /// Types its digit; if the menu is still there a while later (the agent
    /// didn't take it), its options can be tapped again.
    private func choose(_ option: ScreenMenu.Option) {
        chosen = option.number
        Task {
            await answer(option.keys)
            try? await Task.sleep(for: .seconds(3))
            chosen = nil
        }
    }
}

/// The user's messages as bubbles, the agent's as Markdown, notes in small
/// print.
struct MessageView: View {
    let entry: TranscriptEntry

    var body: some View {
        switch entry.kind {
        case .user:
            HStack {
                Spacer(minLength: 44)
                Text(entry.text ?? "")
                    .font(.subheadline)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.16), in: RoundedRectangle(cornerRadius: 16))
            }
        case .assistant:
            MarkdownView(entry.text ?? "")
        case .note:
            Text(entry.text ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)
        case .tool, .toolResult, .unknown:
            EmptyView()
        }
    }
}

/// An agent's Markdown: paragraphs, headings, lists, code (and tables),
/// quotes and rules, each with its inline emphasis, code and links.
struct MarkdownView: View {
    let blocks: [MarkdownBlock]

    init(_ text: String) {
        blocks = Markdown.blocks(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .paragraph(let text):
                    Text(Self.inline(text))
                case .heading(let level, let text):
                    Text(Self.inline(text))
                        .font(level <= 2 ? .headline : .subheadline.weight(.semibold))
                        .padding(.top, 2)
                case .list(let ordered, let items):
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                            HStack(alignment: .firstTextBaseline, spacing: 6) {
                                Text(ordered ? "\(index + 1)." : "•")
                                    .monospacedDigit()
                                    .foregroundStyle(.secondary)
                                Text(Self.inline(item))
                            }
                        }
                    }
                case .code(_, let text):
                    ScrollView(.horizontal, showsIndicators: false) {
                        Text(text)
                            .font(.caption.monospaced())
                            .padding(10)
                    }
                    .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                case .quote(let text):
                    HStack(spacing: 8) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(.tertiary)
                            .frame(width: 3)
                        Text(Self.inline(text))
                            .foregroundStyle(.secondary)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                case .rule:
                    Divider()
                }
            }
        }
        .font(.subheadline)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func inline(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

/// A run of tool calls between messages: one line each, the latest few
/// shown and the rest a tap away.
struct ToolGroupView: View {
    let tools: [TranscriptEntry]
    let project: String?
    @State private var showsAll = false

    private static let shown = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if tools.count > Self.shown, !showsAll {
                let hidden = tools.count - Self.shown
                Button {
                    withAnimation(.snappy) { showsAll = true }
                } label: {
                    Label("\(hidden) more tool call\(hidden == 1 ? "" : "s")", systemImage: "chevron.up")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            ForEach(showsAll ? tools : Array(tools.suffix(Self.shown))) { tool in
                ToolLine(entry: tool, project: project)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 2)
        .background(Color(.secondarySystemFill).opacity(0.5), in: RoundedRectangle(cornerRadius: 12))
    }
}

/// A tool call in one line, its verb and what it acted on; it opens on the
/// start of its result.
struct ToolLine: View {
    let entry: TranscriptEntry
    let project: String?
    @State private var expanded = false

    var body: some View {
        let shown = ToolPresentation(entry, project: project)
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: shown.symbol)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(width: 18)
                    Text("\(Text(shown.title).fontWeight(.medium)) \(Text(shown.detail).font(shown.isCode ? .footnote.monospaced() : .footnote).foregroundStyle(.secondary))")
                        .font(.footnote)
                        .lineLimit(expanded ? nil : 1)
                        .truncationMode(shown.isCode ? .tail : .middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    status
                }
                .padding(.vertical, 7)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded, let result = entry.result, !result.isEmpty {
                ScrollView([.horizontal, .vertical]) {
                    Text(result)
                        .font(.caption2.monospaced())
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 220)
                .fixedSize(horizontal: false, vertical: true)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
                .padding(.bottom, 7)
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch entry.status {
        case .running, nil:
            ProgressView()
                .controlSize(.mini)
        case .ok:
            Image(systemName: "checkmark")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.tertiary)
        case .error:
            Image(systemName: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}
