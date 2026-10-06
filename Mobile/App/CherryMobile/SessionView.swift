import CherryMobileKit
import SwiftUI

/// A session's screen as its host keeps it, and quick replies: a menu's
/// options as buttons, a reply field, and keys.
struct SessionView: View {
    @Environment(AppModel.self) private var model
    let key: SessionKey
    @Binding var path: [Route]

    @State private var screen: ScreenSnapshot?
    @State private var problem: String?

    var body: some View {
        VStack(spacing: 0) {
            ScreenTextView(screen: screen, problem: problem)
            QuickReplyBar(menu: menu, isRunning: session?.isRunning ?? true) { keys in
                await send(keys)
            }
        }
        .navigationTitle(session?.title ?? "Session")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                VStack(spacing: 1) {
                    Text(session?.title ?? "Session").font(.headline)
                    if let mac = model.mac(key.macID) {
                        Text(subtitle(mac: mac)).font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    path.append(.terminal(key, fitsPhone: false))
                } label: {
                    Label("Open Terminal", systemImage: "apple.terminal")
                }
                .disabled(session?.isRunning == false)
            }
        }
        // Reloads when the host says the screen changed, and every few
        // seconds in case an event was missed.
        .task(id: model.screenRevisions[key, default: 0]) { await reload() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await reload()
            }
        }
    }

    private var session: MobileSession? {
        model.session(key)
    }

    private var menu: ScreenMenu? {
        guard let screen, session?.attention != .working else { return nil }
        return ScreenMenu.find(in: screen.lines)
    }

    private func subtitle(mac: AppModel.Mac) -> String {
        [mac.endpoint.name, session?.directory].compactMap { $0 }.joined(separator: " — ")
    }

    private func reload() async {
        do {
            screen = try await model.screen(of: key)
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    private func send(_ keys: [MobileKey]) async {
        do {
            try await model.send(keys, to: key)
            await reload()
        } catch {
            problem = error.localizedDescription
        }
    }
}

/// The screen's text at the session's own width, kept to its bottom.
struct ScreenTextView: View {
    let screen: ScreenSnapshot?
    let problem: String?

    var body: some View {
        ZStack {
            Color(red: 0.07, green: 0.07, blue: 0.09)
            if let screen {
                ScrollView([.vertical, .horizontal]) {
                    Text(text(of: screen))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(Color(white: 0.9))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .defaultScrollAnchor(.bottomLeading)
            } else if problem == nil {
                ProgressView().tint(.white)
            }
            if let problem {
                VStack {
                    Spacer()
                    Label(problem, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .padding(10)
                        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .padding()
                }
            }
        }
    }

    /// Its lines, without the blank ones after the last line with text, and
    /// symbols agents draw as text (Claude's `⏺`) kept text, not emoji.
    private func text(of screen: ScreenSnapshot) -> String {
        var lines = screen.lines
        while let last = lines.last, last.trimmingCharacters(in: .whitespaces).isEmpty {
            lines.removeLast()
        }
        var text = ""
        for scalar in lines.joined(separator: "\n").unicodeScalars {
            text.unicodeScalars.append(scalar)
            if Self.emojiByDefault.contains(scalar.value) {
                text.unicodeScalars.append("\u{FE0E}")
            }
        }
        return text
    }

    /// Symbols iOS draws as emoji unless asked for text.
    private static let emojiByDefault: Set<UInt32> = [
        0x23F5, 0x23F8, 0x23F9, 0x23FA, 0x25B6, 0x2611, 0x2705, 0x2714, 0x2716, 0x274C, 0x26A0,
    ]
}

/// Answers without opening a terminal.
struct QuickReplyBar: View {
    let menu: ScreenMenu?
    let isRunning: Bool
    let send: @MainActor ([MobileKey]) async -> Void

    @State private var reply = ""
    @FocusState private var replyFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let menu {
                MenuButtons(menu: menu, send: send)
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    KeyChip("esc", keys: [.escape], send: send)
                    KeyChip("↑", keys: [.up], send: send)
                    KeyChip("↓", keys: [.down], send: send)
                    KeyChip("⏎", keys: [.enter], send: send)
                    KeyChip("⇥", keys: [.tab], send: send)
                    KeyChip("⌃C", keys: [.controlC], send: send)
                }
            }
            HStack(spacing: 8) {
                TextField("Reply", text: $reply, axis: .vertical)
                    .lineLimit(1...4)
                    .textInputAutocapitalization(.sentences)
                    .focused($replyFocused)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 18))
                    .onSubmit(sendReply)
                Button(action: sendReply) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 30))
                }
                .disabled(reply.isEmpty)
                .accessibilityLabel("Send")
            }
        }
        .disabled(!isRunning)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(.bar)
    }

    private func sendReply() {
        let text = reply
        guard !text.isEmpty else { return }
        reply = ""
        Task { await send([.text(text), .enter]) }
    }
}

/// A menu's options: a button types the option's digit, which an agent
/// takes by itself.
struct MenuButtons: View {
    let menu: ScreenMenu
    let send: @MainActor ([MobileKey]) async -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let question = menu.question {
                Text(question)
                    .font(.subheadline.weight(.semibold))
            }
            ForEach(menu.options, id: \.number) { option in
                Button {
                    Task { await send(option.keys) }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(option.number)")
                            .font(.subheadline.monospacedDigit().weight(.bold))
                            .frame(width: 22, height: 22)
                            .background(option.isSelected ? Color.accentColor : Color.secondary.opacity(0.25), in: Circle())
                            .foregroundStyle(option.isSelected ? Color.white : Color.primary)
                        Text(option.label)
                            .multilineTextAlignment(.leading)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

struct KeyChip: View {
    let title: String
    let keys: [MobileKey]
    let send: @MainActor ([MobileKey]) async -> Void

    init(_ title: String, keys: [MobileKey], send: @escaping @MainActor ([MobileKey]) async -> Void) {
        self.title = title
        self.keys = keys
        self.send = send
    }

    var body: some View {
        Button {
            Task { await send(keys) }
        } label: {
            Text(title)
                .font(.callout.monospaced().weight(.medium))
                .frame(minWidth: 30)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
    }
}
