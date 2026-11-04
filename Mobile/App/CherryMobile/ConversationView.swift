import CherryMobileKit
import SwiftUI

/// An agent's conversation, read from its own session on the Mac (`cherry
/// host transcript`): the latest messages and tool calls, then what comes
/// after them every few seconds, kept to the bottom.
struct ConversationView: View {
    @Environment(AppModel.self) private var model
    let key: SessionKey
    /// Why the Mac's connection is away, shown over the last conversation.
    let reconnecting: String?
    let showScreen: () -> Void

    @State private var conversation = Conversation()
    @State private var problem: MacConnectionError?
    @State private var loaded = false

    /// Entries a first read asks for.
    private static let limit = 150

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                if conversation.moreBefore {
                    Text("Earlier messages aren't shown.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity)
                }
                ForEach(conversation.entries) { entry in
                    TranscriptEntryView(entry: entry)
                }
            }
            .padding(12)
        }
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(.bottom, for: .sizeChanges)
        .overlay { emptyState }
        .overlay(alignment: .bottom) {
            if let note = reconnecting ?? (loaded && !conversation.entries.isEmpty ? problem?.localizedDescription : nil) {
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

    @ViewBuilder
    private var emptyState: some View {
        if let problem, conversation.entries.isEmpty {
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

/// One entry: the user's messages as bubbles, the agent's as text, tool
/// calls as rows that open on their result, notes in small print.
struct TranscriptEntryView: View {
    let entry: TranscriptEntry

    var body: some View {
        switch entry.kind {
        case .user:
            HStack {
                Spacer(minLength: 48)
                Text(entry.text ?? "")
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color.accentColor.opacity(0.15), in: RoundedRectangle(cornerRadius: 16))
            }
        case .assistant:
            Text(Self.markdown(entry.text ?? ""))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .tool:
            ToolCallRow(entry: entry)
        case .note:
            Text(entry.text ?? "")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
        case .toolResult, .unknown:
            EmptyView()
        }
    }

    /// Inline Markdown (emphasis, code, links), its line breaks kept.
    static func markdown(_ text: String) -> AttributedString {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    }
}

struct ToolCallRow: View {
    let entry: TranscriptEntry
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // Opens on the result, or the whole summary while there is none.
            Button {
                withAnimation(.snappy) { expanded.toggle() }
            } label: {
                HStack(spacing: 8) {
                    status
                    Text(entry.name ?? "Tool")
                        .font(.footnote.weight(.semibold))
                    Text(entry.summary ?? "")
                        .font(.footnote.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(expanded ? nil : 1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if entry.result != nil {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(expanded ? .degrees(90) : .zero)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if expanded, let result = entry.result {
                ScrollView(.horizontal) {
                    Text(result)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .padding(8)
                }
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color(.secondarySystemFill).opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder
    private var status: some View {
        switch entry.status {
        case .running, nil:
            ProgressView()
                .controlSize(.mini)
        case .ok:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
        case .error:
            Image(systemName: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.red)
        }
    }
}
