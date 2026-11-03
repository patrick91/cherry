import CherryControl
import Foundation
import Testing
@testable import Cherry

// The sidebar's one mark per row (`SidebarRowMark`), the worker summary on
// a folded orchestrator (`AgentWorkerSummary`) and when the sidebar folds a
// worker group by itself (`AgentGroupAutoCollapse`).

@Test func aWorkerRowShowsOnlyItsTaskState() {
    func mark(_ activity: AgentActivityState, unseen: Bool = false, selected: Bool = false, task: AgentTaskState?) -> SidebarRowMark {
        SidebarRowMark.resolve(activity: activity, hasUnseenResult: unseen, isSelected: selected, taskState: task)
    }
    // Permission and questions need the user: they win over the task.
    #expect(mark(.permission, task: .working) == .permission)
    #expect(mark(.needsInput, task: .reported) == .question)
    // Working is the spinner alone, whatever the agent reports.
    #expect(mark(.working, task: .working) == .working)
    #expect(mark(.unknown, task: .working) == .working)
    // A report: bright while unseen, dim once seen or selected; never also
    // the result indicator.
    #expect(mark(.idle, unseen: true, task: .reported) == .task(.reported, emphasized: true))
    #expect(mark(.idle, unseen: true, selected: true, task: .reported) == .task(.reported, emphasized: false))
    #expect(mark(.idle, task: .reported) == .task(.reported, emphasized: false))
    // Other states keep their glyphs.
    for state in [AgentTaskState.queued, .needsInput, .awaitingApproval, .failed, .noReport, .cancelled] {
        #expect(mark(.idle, unseen: true, task: state) == .task(state, emphasized: true), "\(state)")
    }
    #expect(mark(.error, unseen: true, task: .failed) == .task(.failed, emphasized: true))
    // Back at work after its task settled: the spinner, not how it ended.
    for state in [AgentTaskState.reported, .failed, .noReport, .cancelled] {
        #expect(mark(.working, task: state) == .working, "\(state)")
    }
    #expect(mark(.working, task: .needsInput) == .task(.needsInput, emphasized: true))
}

@Test func aRowWithoutATaskKeepsItsActivityMarks() {
    func mark(_ activity: AgentActivityState, unseen: Bool = false, selected: Bool = false) -> SidebarRowMark {
        SidebarRowMark.resolve(activity: activity, hasUnseenResult: unseen, isSelected: selected, taskState: nil)
    }
    #expect(mark(.permission) == .permission)
    #expect(mark(.needsInput) == .question)
    #expect(mark(.idle, unseen: true) == .result(failed: false))
    #expect(mark(.error, unseen: true) == .result(failed: true))
    #expect(mark(.idle, unseen: true, selected: true) == .none)
    #expect(mark(.working) == .working)
    #expect(mark(.working, unseen: true) == .result(failed: false))
    #expect(mark(.idle) == .none)
}

@Test func aWorkerSummaryCountsEachWorkersLatestTask() {
    var summary = AgentWorkerSummary()
    let ids = (0..<4).map { _ in UUID() }
    summary.add(.reported, worker: ids[0])
    summary.add(.noReport, worker: ids[1])
    summary.add(.failed, worker: ids[2])
    #expect(summary.allSettled && summary.text == "1 done · 2 failed")
    #expect(summary.finishedWorkerIDs == Array(ids[0..<3]))
    summary.add(.awaitingApproval, worker: ids[3])
    #expect(!summary.allSettled && summary.finishedWorkerIDs.count == 3)

    var done = AgentWorkerSummary()
    for _ in 0..<10 { done.add(.reported, worker: UUID()) }
    #expect(done.text == "10 done")
    var cancelled = AgentWorkerSummary()
    cancelled.add(.cancelled, worker: UUID())
    #expect(cancelled.text == "1 cancelled")
    #expect(!AgentWorkerSummary().allSettled)
}

@Test func aWorkerGroupFoldsOnItsSettleAndTheUsersChoiceSticks() {
    let owner = UUID()
    func summary(open: Int, reported: Int) -> [UUID: AgentWorkerSummary] {
        var value = AgentWorkerSummary()
        for _ in 0..<open { value.add(.working, worker: UUID()) }
        for _ in 0..<reported { value.add(.reported, worker: UUID()) }
        return [owner: value]
    }
    var collapse = AgentGroupAutoCollapse()

    // Restored already settled (first seen): no transition, nothing folds.
    #expect(collapse.update(from: [:], to: summary(open: 0, reported: 2), collapsed: []) == .init())
    // A new task opens, then settles: it folds.
    #expect(collapse.update(from: summary(open: 0, reported: 2), to: summary(open: 1, reported: 2), collapsed: []) == .init())
    #expect(collapse.update(from: summary(open: 1, reported: 2), to: summary(open: 0, reported: 3), collapsed: [])
        == .init(collapse: [owner]))
    // Another task opens: the group it folded unfolds for the new worker.
    #expect(collapse.update(from: summary(open: 0, reported: 3), to: summary(open: 1, reported: 3), collapsed: [owner])
        == .init(expand: [owner]))
    // Settled again, but the user unfolds it: it stays unfolded while
    // nothing settles again, and a new open task does not touch it.
    #expect(collapse.update(from: summary(open: 1, reported: 3), to: summary(open: 0, reported: 4), collapsed: [])
        == .init(collapse: [owner]))
    collapse.userToggled(owner)
    #expect(collapse.update(from: summary(open: 0, reported: 4), to: summary(open: 0, reported: 4), collapsed: []) == .init())
    #expect(collapse.update(from: summary(open: 0, reported: 4), to: summary(open: 1, reported: 4), collapsed: []) == .init())
    // A group the user folded is never unfolded by a new task.
    collapse.userToggled(owner)
    #expect(collapse.update(from: summary(open: 1, reported: 4), to: summary(open: 2, reported: 4), collapsed: [owner]) == .init())
}
