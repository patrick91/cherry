import Foundation

/// Tells an agent that went back to work by itself after its turn ended (a
/// background agent's or task's result it answers, a scheduled wake-up or
/// loop iteration, a workflow's notification, a hook that continues it) from
/// a stale frame of its finished screen: a repaint, a resize's reflow, a
/// scroll, the user moving the cursor.
///
/// A stale frame is frozen; real work advances. While an agent works, its
/// live-work lines (`AgentScreenActivity.workingLines`: Claude's status line
/// "✶ Pondering… (12s · ↓ 1.2k tokens)", a task row's meter, Codex's
/// "Working (12s • esc to interrupt)") change several times a second (the
/// spinner glyph, the elapsed counter, the token meter), and its title's
/// braille spinner pulses. So the agent counts as back at work only once
///
/// - its live-work lines changed `requiredChanges` times within `window`,
///   the first and last of those changes at least `minimumSpan` apart, each
///   time in place (the same rows, counted from the bottom of the screen,
///   as the frame before: a status line is redrawn where it stands, while
///   scrolling moves lines), to text not shown before since the turn ended:
///   never a line of the finished screen or of a screen a layout change
///   redrew (`arm`, `noteScreen`), never a frame shown before (flapping
///   between two frames, or between the surface and the host, is not
///   progress), never within `inputQuietInterval` of a key (the change may
///   be the user's), and with the grid unchanged (a resize resets it); or
/// - its title's spinner changed `requiredChanges` times within `window`,
///   at least `minimumSpan` apart (programs set titles; a repaint does not).
///
/// One frozen frame of a working marker after a finished turn (a wobble)
/// therefore never starts a turn. Pure: the session feeds it its screen and
/// title (`TerminalSession.noteAgentScreenForResumedWork`).
struct AgentResumedWorkDetector {
    /// Changes older than this are forgotten.
    static let window: TimeInterval = 4
    /// The first and last counted change must be this far apart: a burst of
    /// redraws (a resize, a repaint written in several parts) is shorter.
    static let minimumSpan: TimeInterval = 1
    /// Changes needed within `window`: three frames in a row, each new.
    static let requiredChanges = 2
    /// A screen change this soon after a key or input may be the user's own
    /// (moving the cursor, scrolling a TUI's transcript): it does not count.
    static let inputQuietInterval: TimeInterval = 1
    /// The stale lines kept at most; past this they start again from the
    /// current screen.
    static let staleLineLimit = 1_024

    /// What the screen is laid out for: a change redraws (reflows) it.
    struct Layout: Equatable {
        var columns: Int
        var rows: Int
        /// The lines come from the session's host, not its surface.
        var fromHost: Bool
    }

    /// One source of evidence: the screen's live-work lines or the title.
    private struct Channel {
        var last: String?
        var lastPlacement: [Int] = []
        var seen: Set<String> = []
        var changes: [Date] = []

        /// Notes `signature` (nil: no evidence now), shown at `placement`,
        /// and returns whether the evidence has advanced for long enough. A
        /// change counts only at the placement of the frame before.
        /// `requiresNew`: only to a signature not seen before. `counts`
        /// false: a change is taken in, but not counted.
        mutating func note(
            _ signature: String?,
            placement: [Int] = [],
            requiresNew: Bool,
            counts: Bool,
            now: Date
        ) -> Bool {
            guard let signature else {
                // The evidence went: the next one to show is a first frame.
                last = nil
                return false
            }
            let previousPlacement = lastPlacement
            lastPlacement = placement
            guard signature != last else { return false }
            let previous = last
            last = signature
            if seen.count >= AgentResumedWorkDetector.staleLineLimit { seen.removeAll() }
            let isNew = seen.insert(signature).inserted
            // The first frame is no change: a frozen repaint shows one.
            guard previous != nil, placement == previousPlacement, counts, isNew || !requiresNew else {
                return false
            }
            changes.append(now)
            changes.removeAll { now.timeIntervalSince($0) > AgentResumedWorkDetector.window }
            guard changes.count >= AgentResumedWorkDetector.requiredChanges, let first = changes.first else {
                return false
            }
            return now.timeIntervalSince(first) >= AgentResumedWorkDetector.minimumSpan
        }
    }

    /// Watching: a turn ended (`arm`) and none started since (`disarm`).
    private(set) var isArmed = false
    private var layout: Layout?
    private var staleLines: Set<String> = []
    private var screen = Channel()
    private var title = Channel()

    /// The agent's turn ended: every line `screenLines` shows now is the
    /// past, and only work that advances from here on is a new turn.
    mutating func arm(screenLines: [String], layout: Layout) {
        self = Self()
        isArmed = true
        self.layout = layout
        absorb(screenLines)
    }

    /// A turn started (submitted, or resumed by the agent): stop watching.
    mutating func disarm() {
        self = Self()
    }

    /// One look at the screen: `screenLines` is its tail,
    /// `workingLineIndices` the indices of its lines that show a turn in
    /// flight (`AgentScreenActivity.workingLineIndices`), `lastInputAt` the
    /// last key or input sent to the agent. True when the agent is back at
    /// work.
    mutating func noteScreen(
        _ screenLines: [String],
        workingLineIndices: [Int],
        layout: Layout,
        lastInputAt: Date?,
        now: Date
    ) -> Bool {
        guard isArmed else { return false }
        guard layout == self.layout else {
            // A resize reflows the screen, and a switch between the surface
            // and the host shows it anew: what it shows now is the past,
            // redrawn.
            self.layout = layout
            absorb(screenLines)
            screen = Channel()
            return false
        }
        var end = screenLines.count
        while end > 0, screenLines[end - 1].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            end -= 1
        }
        // Each fresh line with its row counted from the last one with text.
        let fresh = workingLineIndices.compactMap { index -> (row: Int, text: String)? in
            guard screenLines.indices.contains(index) else { return nil }
            let text = screenLines[index].trimmingCharacters(in: .whitespacesAndNewlines)
            return staleLines.contains(text) ? nil : (end - index, text)
        }
        let afterInput = lastInputAt.map { now.timeIntervalSince($0) < Self.inputQuietInterval } ?? false
        return screen.note(
            fresh.isEmpty ? nil : fresh.map(\.text).joined(separator: "\n"),
            placement: fresh.map(\.row),
            requiresNew: true,
            counts: !afterInput,
            now: now
        )
    }

    /// The terminal title is now `title`; `isSpinner` when it shows a
    /// spinner frame (a working agent's). True when the agent is back at
    /// work.
    mutating func noteTitle(_ title: String, isSpinner: Bool, now: Date) -> Bool {
        guard isArmed else { return false }
        // A spinner cycles through a few frames: they repeat.
        return self.title.note(isSpinner ? title : nil, requiresNew: false, counts: true, now: now)
    }

    private mutating func absorb(_ lines: [String]) {
        if staleLines.count >= Self.staleLineLimit { staleLines.removeAll() }
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { staleLines.insert(trimmed) }
        }
    }
}
