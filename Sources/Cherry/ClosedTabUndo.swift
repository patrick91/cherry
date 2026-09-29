import AppKit

// Undoing a tab close or detach (docs/specs/multiplexer-default.md, "Undo"):
// ⌘Z, Edit › Undo, and the toast's Undo (a close) or Reopen (a detach) bring
// back the tabs a user's close (⌘W, Close) or detach (⌘D, Detach) took out of
// a project window that stays open, where they were, for as long as their
// toast would stay. A close of this app's own persistent tab only stops its
// adapter meanwhile: its session ends once the close can no longer be undone.

/// Where a tab was in its workspace when it closed, so that undoing the
/// close puts it back there (`TerminalWorkspace.reopenClosedTab`).
struct ClosedTabPlacement: Equatable {
    enum Display: Equatable {
        /// A tab of its own in the terminal list, at this display index.
        case standalone(index: Int)
        /// A pane of split group `groupID` (shown at `displayIndex`), whose
        /// panes and width weights were `paneIDs` and `widthWeights`.
        case pane(groupID: UUID, displayIndex: Int, paneIDs: [UUID], widthWeights: [Double])
    }

    /// Its index among the workspace's tabs (the sidebar's order).
    var sessionIndex: Int
    /// Its terminal display item; nil for an agent or command tab.
    var display: Display?
    /// It was the selected tab (or the focused pane).
    var wasSelected: Bool
    /// The agents that were its sub-agents, which its close made top-level.
    var subAgentIDs: [UUID]
}

/// A tab a user's close or detach took out of its window, as undoing that
/// brings it back (`ClosedTabHistory`), read before it closed
/// (`TerminalWorkspace.closedTab(for:name:)`).
struct ClosedTab {
    /// The tab as workspace persistence saves it: its id, kind, title,
    /// agent, parent agent, command, launch settings and session.
    let record: WorkspaceSessionRecord
    /// Its sidebar name, for its toast.
    let name: String
    /// The host session it showed, which undo attaches to again.
    let binding: HostedSessionAttachment
    /// It was this app's own persistent tab, whose session comes back as the
    /// tab's own; else it was attached to a session it did not own, and is
    /// attached to it again.
    let ownsSession: Bool
    let placement: ClosedTabPlacement
    /// The host that ends its session once its close can no longer be
    /// undone (`PersistentLocalSessions.deferEnd`): a close of this app's own
    /// persistent tab. Nil when nothing ends with it (a detach, or a tab
    /// attached to a session it did not own).
    var pendingEnd: PersistentLocalSessions?
}

/// A project window's tabs that a user's close or detach took away and that
/// ⌘Z (Edit › Undo, through `ClosedTabUndoManager`) or their toast's Undo or
/// Reopen can still bring back where they were, the latest first. Each
/// entry (one close or detach: a tab, or a split or agent group) stays as
/// long as its toast would (`ProjectWindowToasts.lifetime`: 6 s, 30 s with
/// VoiceOver), its time stopped while the pointer rests on its toast (while
/// that toast is the one shown) and while its window is not key in the
/// active app; a close whose sessions end with it waits for the window at
/// most `longestUnattendedWait`, as its programs, which nothing else shows,
/// keep running meanwhile. Each keeps its own time: a newer toast replacing
/// its toast leaves it as it is. When it runs out, the entry goes and so
/// does its toast; a closed tab's session then ends (its end waited:
/// `PersistentLocalSessions.deferEnd`), while a detached tab's stays in the
/// background, in Background Sessions. Its window closing, or Cherry
/// quitting, ends them all at once (`endAll`).
@MainActor
final class ClosedTabHistory {
    enum Action: Equatable, Sendable {
        case close
        case detach
    }

    /// What one close or detach took away.
    struct Entry {
        let id: UUID
        let action: Action
        let tabs: [ClosedTab]
        weak var workspace: TerminalWorkspace?
        /// The window's repository, which shows the workspace's worktree.
        weak var repository: RepositoryWorkspace?
        fileprivate(set) var timing: ToastLifetime
        /// Its toast (Undo, or a detach's Reopen), which may be on screen.
        fileprivate(set) var toastID: UUID?

        /// Sessions end with it once it runs out (a close of this app's
        /// own persistent tab).
        var endsSessions: Bool {
            tabs.contains { $0.pendingEnd != nil }
        }

        /// How Edit › Undo names it: "Undo Close Tab", "Undo Detach Tabs".
        var actionName: String {
            let tab = tabs.count == 1 ? "Tab" : "Tabs"
            switch action {
            case .close: return "Close \(tab)"
            case .detach: return "Detach \(tab)"
            }
        }
    }

    /// Oldest first.
    private(set) var entries: [Entry] = []
    /// What the window's Edit › Undo asks while no text view has the keyboard.
    let undoManager = ClosedTabUndoManager()
    /// Selects the tabs that come back (the window's chrome state sets it).
    weak var chromeState: ProjectWindowChromeState?
    /// Dismisses an entry's toast when the entry goes (the window's chrome
    /// state sets it: `ProjectWindowToasts.dismiss(id:)`).
    var dismissToast: (@MainActor (UUID) -> Void)?
    /// The toast the pointer rests on (`ProjectWindowToasts.hoverDidChange`).
    private var hoveredToastID: UUID?
    /// Whether the window is key in the active app (`setAttended`).
    private var isAttended = true
    /// Since when the window has not been key in the active app.
    private var unattendedSince: Date?
    /// The longest a close whose sessions end with it
    /// (`Entry.endsSessions`) waits for its window to be key again: its
    /// time then runs anyway. Its programs keep running until it ends, and
    /// nothing shows them meanwhile (not the sidebar, Background Sessions
    /// or MCP), so a window left in the background must not keep them
    /// running for hours.
    static let longestUnattendedWait: TimeInterval = 4
    /// Only the latest scheduled check may act.
    private var checkGeneration = 0
    private let now: @MainActor () -> Date
    private let schedule: ProjectWindowToasts.Scheduler
    private let voiceOverEnabled: @MainActor () -> Bool

    /// The app uses the defaults; tests inject a clock, a scheduler and
    /// whether VoiceOver runs.
    init(
        now: @escaping @MainActor () -> Date = { Date() },
        schedule: @escaping ProjectWindowToasts.Scheduler = ProjectWindowToasts.scheduleOnMainQueue,
        voiceOverEnabled: @escaping @MainActor () -> Bool = ProjectWindowToasts.isVoiceOverEnabled
    ) {
        self.now = now
        self.schedule = schedule
        self.voiceOverEnabled = voiceOverEnabled
        undoManager.history = self
    }

    /// On the clock of the window's toasts, so an entry and its toast keep
    /// the same time.
    convenience init(clockOf toasts: ProjectWindowToasts) {
        self.init(now: toasts.now, schedule: toasts.schedule, voiceOverEnabled: toasts.voiceOverEnabled)
    }

    /// Adds what a close or detach just took out of `workspace`; nil when
    /// none of it can come back.
    @discardableResult
    func record(
        _ tabs: [ClosedTab],
        action: Action,
        workspace: TerminalWorkspace,
        repository: RepositoryWorkspace?
    ) -> UUID? {
        guard !tabs.isEmpty else { return nil }
        let entry = Entry(
            id: UUID(),
            action: action,
            tabs: tabs,
            workspace: workspace,
            repository: repository,
            timing: ToastLifetime(
                lifetime: ProjectWindowToasts.lifetime(of: .standard, voiceOverEnabled: voiceOverEnabled()),
                shownAt: now()
            )
        )
        entries.append(entry)
        updateTiming()
        return entry.id
    }

    /// `toastID` is entry `entryID`'s toast: the pointer resting on it stops
    /// the entry's time, and the entry going dismisses it.
    func setToast(_ toastID: UUID, for entryID: UUID) {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return }
        entries[index].toastID = toastID
        updateTiming()
    }

    /// The pointer rests on toast `id` now (nil: on none).
    func setHoveredToast(_ id: UUID?) {
        guard hoveredToastID != id else { return }
        hoveredToastID = id
        updateTiming()
    }

    /// The window became key in the active app, or stopped being: nobody
    /// sees its toasts meanwhile, so the entries' time stops.
    func setAttended(_ attended: Bool) {
        guard isAttended != attended else { return }
        isAttended = attended
        unattendedSince = attended ? nil : now()
        updateTiming()
    }

    /// What ⌘Z brings back now: the latest entry whose workspace is still
    /// open.
    var latest: Entry? {
        entries.last { entry in
            entry.workspace.map { !$0.isTornDown } ?? false
        }
    }

    /// ⌘Z: brings back the latest entry's tabs (`restore`). One that brings
    /// back none (its workspace went, its sessions ended) is dropped, and the
    /// one before is tried. False when none came back.
    @discardableResult
    func undoLatest() -> Bool {
        defer { scheduleCheck() }
        while let entry = entries.popLast() {
            if restore(entry) { return true }
        }
        return false
    }

    /// The toast's Undo or Reopen: brings back entry `entryID`'s tabs. False
    /// when it is gone, or none came back.
    @discardableResult
    func undo(_ entryID: UUID) -> Bool {
        guard let index = entries.firstIndex(where: { $0.id == entryID }) else { return false }
        let entry = entries.remove(at: index)
        defer { scheduleCheck() }
        return restore(entry)
    }

    /// The window closes, or Cherry quits: every entry goes now, and the
    /// closed tabs' sessions end.
    func endAll() {
        let ended = entries
        entries.removeAll()
        checkGeneration += 1
        ended.forEach(end)
    }

    /// Brings `entry`'s tabs back where they were
    /// (`TerminalWorkspace.reopenClosedTab`), in their order, and shows them:
    /// their worktree, and the one that was selected (else the first).
    /// Sessions whose end waited get it back first; a tab that cannot come
    /// back ends as its close asked. False when none came back.
    private func restore(_ entry: Entry) -> Bool {
        if let toastID = entry.toastID { dismissToast?(toastID) }
        guard let workspace = entry.workspace, !workspace.isTornDown,
              entry.repository.map({ $0.allLoadedWorkspaces().contains { $0 === workspace } }) ?? true
        else {
            end(entry)
            return false
        }
        var restored: [(tab: ClosedTab, session: TerminalSession)] = []
        for tab in entry.tabs.sorted(by: { $0.placement.sessionIndex < $1.placement.sessionIndex }) {
            let sessionID = tab.binding.sessionID
            // Ended meanwhile (its window's quit or close, or an End).
            if let host = tab.pendingEnd, !host.resumeDeferred(sessionID) { continue }
            if let session = workspace.reopenClosedTab(tab) {
                restored.append((tab, session))
            } else if let host = tab.pendingEnd {
                host.end(tab.binding)
            }
        }
        guard let shown = (restored.first { $0.tab.placement.wasSelected } ?? restored.first)?.session else {
            return false
        }
        if let repository = entry.repository, repository.activeWorkspace !== workspace,
           let root = repository.root(containing: shown.id) {
            repository.activate(worktreeRoot: root, chromeState: chromeState)
        }
        workspace.select(shown)
        chromeState?.selectTerminal()
        return true
    }

    /// `entry` goes: its toast too, and its closed tabs' sessions end.
    private func end(_ entry: Entry) {
        if let toastID = entry.toastID { dismissToast?(toastID) }
        for tab in entry.tabs {
            tab.pendingEnd?.endDeferred(tab.binding.sessionID)
        }
    }

    /// Runs each entry's time, or stops it while the pointer rests on its
    /// toast or the window is not key in the active app (for a close whose
    /// sessions end with it, `longestUnattendedWait` at most); then
    /// schedules the next check.
    private func updateTiming() {
        applyPauses()
        scheduleCheck()
    }

    private func applyPauses() {
        let now = now()
        let waitedLongest = unattendedSince.map { now.timeIntervalSince($0) >= Self.longestUnattendedWait } ?? false
        for index in entries.indices {
            let hovered = entries[index].toastID.map { $0 == hoveredToastID } ?? false
            let waitsForWindow = !isAttended && !(waitedLongest && entries[index].endsSessions)
            if hovered || waitsForWindow {
                entries[index].timing.pause(at: now)
            } else {
                entries[index].timing.resume(at: now)
            }
        }
    }

    /// When the first running entry runs out, or a close whose sessions
    /// end with it has waited longest for the window. Other paused ones
    /// wait for the pointer to leave their toast or the window to be key
    /// again.
    private func scheduleCheck() {
        checkGeneration += 1
        let generation = checkGeneration
        var next = entries.compactMap(\.timing.deadline).min()
        if let unattendedSince, entries.contains(where: { $0.endsSessions && $0.timing.isPaused }) {
            let waitEnds = unattendedSince.addingTimeInterval(Self.longestUnattendedWait)
            if waitEnds > now() { next = min(next ?? waitEnds, waitEnds) }
        }
        guard let next else { return }
        schedule(max(0, next.timeIntervalSince(now()))) { [weak self] in
            guard let self, self.checkGeneration == generation else { return }
            self.expireDue()
        }
    }

    private func expireDue() {
        applyPauses()
        let now = now()
        let due = entries.filter { $0.timing.isExpired(at: now) }
        entries.removeAll { $0.timing.isExpired(at: now) }
        due.forEach(end)
        scheduleCheck()
    }
}

/// What Edit › Undo acts on in a project window while no text view has the
/// keyboard (`ClosedTabUndoRouting`): the window's closed tabs
/// (`ClosedTabHistory`). The window's delegate hands it to AppKit
/// (`ProjectWindowCloseDelegate.windowWillReturnUndoManager`), whose Undo
/// item asks it whether it can undo and what to call it ("Undo Close Tab",
/// "Undo Detach Tab"). A stand-in: nothing registers in it, and it has no
/// Redo.
final class ClosedTabUndoManager: UndoManager {
    weak var history: ClosedTabHistory?

    private var latestActionName: String? {
        MainActor.assumeIsolated { history?.latest?.actionName }
    }

    override var canUndo: Bool { latestActionName != nil }
    override var canRedo: Bool { false }
    override var undoActionName: String { latestActionName ?? "" }
    override var redoActionName: String { "" }
    /// Plain "Undo" (as its own empty stack says it) when there is nothing.
    override var undoMenuItemTitle: String {
        latestActionName.map { undoMenuTitle(forUndoActionName: $0) } ?? super.undoMenuItemTitle
    }
    override var redoMenuItemTitle: String { super.redoMenuItemTitle }

    override func undo() {
        MainActor.assumeIsolated {
            if history?.undoLatest() != true { NSSound.beep() }
        }
    }

    override func undoNestedGroup() {
        undo()
    }

    override func redo() {}
}

/// Where ⌘Z and Edit › Undo go in a project window.
enum ClosedTabUndoRouting {
    /// Whether they act on the window's closed tabs (`ClosedTabHistory`)
    /// while `firstResponder` has the keyboard: the terminal, the sidebar,
    /// or any view but a text view. A text view (an `NSText`: the notes
    /// editor, or the editor of a search or name field) keeps its own text
    /// undo, as ever; closed tabs never join its undo.
    static func actsOnClosedTabs(firstResponder: NSResponder?) -> Bool {
        !(firstResponder is NSText) && !(firstResponder is NSTextField)
    }
}
