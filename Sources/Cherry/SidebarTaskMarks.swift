import CherryControl
import Foundation

/// The one status mark a sidebar row shows. A Cherry task's worker shows
/// its task's state, unless its agent asks for permission or a question
/// (those need the user); any other agent shows its activity, or a result
/// the user has not seen.
enum SidebarRowMark: Equatable {
    case none
    case permission
    case question
    /// The working spinner.
    case working
    /// A finished or failed turn the user has not seen (not a worker).
    case result(failed: Bool)
    /// A worker's task state; `emphasized` false dims it (a report the user
    /// has seen).
    case task(AgentTaskState, emphasized: Bool)

    static func resolve(
        activity: AgentActivityState,
        hasUnseenResult: Bool,
        isSelected: Bool,
        taskState: AgentTaskState?
    ) -> SidebarRowMark {
        if activity == .permission { return .permission }
        if activity == .needsInput { return .question }
        guard let taskState else {
            if hasUnseenResult, !isSelected { return .result(failed: activity == .error) }
            return activity == .working ? .working : .none
        }
        switch taskState {
        case .working:
            return .working
        case .reported:
            return .task(.reported, emphasized: hasUnseenResult && !isSelected)
        case .queued, .needsInput, .awaitingApproval, .failed, .noReport, .cancelled:
            return .task(taskState, emphasized: true)
        }
    }

    /// What VoiceOver says for the row's mark.
    var accessibilityLabel: String? {
        switch self {
        case .none: nil
        case .permission: "Agent waiting for permission"
        case .question: "Agent asking a question"
        case .working: "Working"
        case .result(let failed): failed ? "Program failed" : "Result ready"
        case .task(let state, let emphasized):
            state == .reported && emphasized ? "Task: Reported, not seen yet" : "Task: \(state.displayName)"
        }
    }
}

/// Which orchestrators' worker groups the sidebar folds or unfolds by
/// itself: a group folds when its last open task settles; one it folded
/// unfolds when a new task opens, unless the user folded or unfolded it
/// since (the user's choice sticks until the next settle).
struct AgentGroupAutoCollapse: Equatable {
    /// The groups this folded and the user has not touched since.
    private(set) var folded: Set<UUID> = []

    struct Change: Equatable {
        var collapse: Set<UUID> = []
        var expand: Set<UUID> = []
    }

    mutating func update(
        from old: [UUID: AgentWorkerSummary],
        to new: [UUID: AgentWorkerSummary],
        collapsed: Set<UUID>
    ) -> Change {
        var change = Change()
        for (owner, summary) in new {
            // An orchestrator not seen before (a launch's restored runs) is
            // no transition.
            let wasSettled = old[owner]?.allSettled ?? summary.allSettled
            if summary.allSettled, !wasSettled, !collapsed.contains(owner) {
                change.collapse.insert(owner)
                folded.insert(owner)
            } else if !summary.allSettled, folded.contains(owner) {
                folded.remove(owner)
                if collapsed.contains(owner) { change.expand.insert(owner) }
            }
        }
        folded = folded.filter { new[$0] != nil }
        return change
    }

    /// The user folded or unfolded `owner`: leave it as they set it.
    mutating func userToggled(_ owner: UUID) {
        folded.remove(owner)
    }
}

extension TerminalWorkspace {
    /// `owner`'s sub-agents whose latest task settled (Close Finished
    /// Workers), in the sidebar's order.
    func finishedWorkers(of owner: TerminalSession, summaries: [UUID: AgentWorkerSummary]) -> [TerminalSession] {
        guard let finished = summaries[owner.id]?.finishedWorkerIDs, !finished.isEmpty else { return [] }
        let ids = Set(finished)
        return descendantAgentSessions(of: owner).filter { ids.contains($0.id) }
    }
}
