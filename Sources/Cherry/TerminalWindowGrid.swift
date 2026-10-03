import AppKit

/// The grid a project window gives its terminals, and since when: what a
/// new persistent tab's Create starts its program at (`TerminalWindowGridWait`).
/// Each surface laid out in the window notes its grid as Ghostty reports it
/// (`GhosttySessionBridge.reportWindowGrid`); one is shared by every
/// worktree's workspace of a window (`RepositoryWorkspace`), and it keeps
/// the last grid after its surface goes (another tab shown, a worktree with
/// no tabs).
@MainActor
final class TerminalWindowGrid {
    struct Record {
        let grid: TerminalViewportSize
        /// When the window's terminal got this grid.
        let since: ContinuousClock.Instant
        weak var window: NSWindow?
    }

    private(set) var record: Record?

    /// A surface laid out in `window` has `grid`. The record, and its time,
    /// change only with the grid or the window: another tab shown at the
    /// grid the window has (a new tab, a switch) changes nothing.
    func note(_ grid: TerminalViewportSize, in window: NSWindow, now: ContinuousClock.Instant = .now) {
        if let record, record.grid == grid, record.window === window { return }
        record = Record(grid: grid, since: now, window: window)
    }

    /// The record as a Create's wait looks at it, with whether its window is
    /// settling now (`TerminalWindowSettling`).
    func observation(
        isSettling: (NSWindow?) -> Bool = { TerminalWindowSettling.shared.isSettling($0) }
    ) -> TerminalWindowGridWait.Observation? {
        guard let record else { return nil }
        return TerminalWindowGridWait.Observation(
            grid: record.grid,
            since: record.since,
            settling: isSettling(record.window)
        )
    }
}

/// When a new persistent session takes its window's terminal grid (its
/// Create's `cols` and `rows`), so its program starts at the size its tab
/// shows and is not resized (and redrawn) a moment later: once that grid
/// stayed the same for `quietPeriod` while the window is not settling
/// (`TerminalWindowSettling`). A new window's terminal is laid out at the
/// window's first frame (SwiftUI's default size, or its saved one), and a
/// tiling window manager may then move the window: AeroSpace re-tiles a new
/// Cherry window 90 to 290 ms after its terminal is first laid out, in two
/// steps about 20 ms apart; nothing tells a window that no manager will, so
/// every new window's first tab waits the quiet period (its program starts
/// that much later, less the time connecting to the host and building the
/// launch spec took meanwhile). The wait is bounded: `maximumWait` after the
/// Create was asked for (`maximumSettlingWait` while the window settles, as
/// a window restored into full screen does), after which the Create takes
/// the grid it knows (`grid(own:window:tab:)`). A window whose grid has not
/// changed for a while (a new tab in a window that is open) is not waited
/// for.
struct TerminalWindowGridWait: Equatable, Sendable {
    var quietPeriod: Duration
    var maximumWait: Duration
    var maximumSettlingWait: Duration
    /// How often the grid is looked at while waiting.
    var pollInterval: Duration = .milliseconds(15)

    /// The app's windows (`SessionBackendPolicy.windowGridWait`).
    static let standard = TerminalWindowGridWait(
        quietPeriod: .milliseconds(300),
        maximumWait: .seconds(1),
        // As long as a window counts as settling at most
        // (`TerminalWindowSettling.maximumSettling`).
        maximumSettlingWait: .seconds(3)
    )

    /// The window's terminal grid, since when it has it
    /// (`TerminalWindowGrid`), and whether the window is settling.
    struct Observation: Equatable, Sendable {
        var grid: TerminalViewportSize
        var since: ContinuousClock.Instant
        var settling: Bool
    }

    enum Decision: Equatable, Sendable {
        /// The window's grid settled: the Create takes it.
        case take
        /// Look again, at the latest at this instant.
        case wait(until: ContinuousClock.Instant)
        /// Waited as long as it may: the Create takes the grid known now.
        case giveUp
    }

    /// What a Create asked for at `startedAt` does at `now`, given what its
    /// window shows (nil: no terminal of its window was laid out yet).
    /// `sawSettling`: the window was settling at some point of this wait,
    /// which then lasts up to `maximumSettlingWait`, so the grid its window
    /// lays out once settled (just after, as a rule) is the one taken.
    func decision(
        for observation: Observation?,
        startedAt: ContinuousClock.Instant,
        now: ContinuousClock.Instant,
        sawSettling: Bool = false
    ) -> Decision {
        let settling = observation?.settling ?? false
        let deadline = startedAt + (settling || sawSettling ? maximumSettlingWait : maximumWait)
        if let observation, !settling {
            let settled = observation.since + quietPeriod
            if now >= settled { return .take }
            return now >= deadline ? .giveUp : .wait(until: min(settled, deadline))
        }
        return now >= deadline ? .giveUp : .wait(until: deadline)
    }

    /// The grid a new session starts at: its own terminal's while a window
    /// shows it (its pane's, where the window splits), else its window's
    /// (`TerminalWindowGrid`), else the one the tab has (a grid its window
    /// seeded it with, or the default, 120x32).
    static func grid(
        own: TerminalViewportSize?,
        window: TerminalViewportSize?,
        tab: TerminalViewportSize
    ) -> TerminalViewportSize {
        own ?? window ?? tab
    }
}
