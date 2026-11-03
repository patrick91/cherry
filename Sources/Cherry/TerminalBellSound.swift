import AppKit

extension TerminalBell {
    /// Rings a tab's bell (Ghostty's `ring_bell`, or one a persistent tab's
    /// host reported) as Settings › Notifications › Terminal bell says:
    /// Beep plays the system beep, Silent nothing. It decides the sound
    /// only: a background session's bell still posts its notification, and
    /// tests that replace `TerminalSession.bellHandler` still see every
    /// bell. `play` is the beep; tests pass their own.
    @MainActor
    static func ring(
        _ setting: TerminalBell = TerminalSettings.shared.terminalBell,
        play: () -> Void = { NSSound.beep() }
    ) {
        guard setting == .beep else { return }
        play()
    }
}
