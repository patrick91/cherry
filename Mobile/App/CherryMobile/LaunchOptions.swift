import Foundation

/// Launch arguments for screenshots and demos (`Mobile/Scripts/screenshots`):
/// `-screen inbox`, `-screen session:<id>`, `-screen terminal:<id>`,
/// `-screen terminal-fit:<id>` or `-screen macs` opens that screen against
/// the Demo Mac. A run with `-screen` uses only the Demo Mac and connects
/// nowhere else. `-demoDropAfter <seconds>` makes the Demo Mac drop each
/// connection that long after it opened, to show reconnecting.
/// `-demoLongConversation YES` seeds 200 entries for Pi.
/// `-demoTurnSeconds <seconds>` sets the duration of an agent turn.
/// `-demoIncremental YES` adds tool calls separately during a turn.
/// `-pairing <cherry-mobile://pair?…>` opens that pairing code as the
/// camera would, without iOS asking first.
struct LaunchOptions: Equatable, Sendable {
    enum Screen: Equatable, Sendable {
        case inbox
        case session(String)
        case terminal(String, fitsPhone: Bool)
        case macs
    }

    var screen: Screen?
    var demoDropsAfter: Duration?
    var demoLongConversation = false
    var demoIncremental = false
    var demoTurnDuration: Duration = .seconds(4)
    var pairing: URL?

    /// Only the Demo Mac: saved Macs are neither shown nor connected.
    var demoOnly: Bool {
        screen != nil
    }

    static var current: LaunchOptions {
        var options = LaunchOptions(argument: UserDefaults.standard.string(forKey: "screen"))
        let drop = UserDefaults.standard.double(forKey: "demoDropAfter")
        if drop > 0 { options.demoDropsAfter = .milliseconds(Int(drop * 1000)) }
        options.demoLongConversation = UserDefaults.standard.bool(forKey: "demoLongConversation")
        options.demoIncremental = UserDefaults.standard.bool(forKey: "demoIncremental")
        let turn = UserDefaults.standard.double(forKey: "demoTurnSeconds")
        if turn > 0 { options.demoTurnDuration = .milliseconds(Int(turn * 1000)) }
        options.pairing = UserDefaults.standard.string(forKey: "pairing").flatMap(URL.init(string:))
        return options
    }

    init(screen: Screen? = nil) {
        self.screen = screen
    }

    init(argument: String?) {
        guard let argument else {
            screen = nil
            return
        }
        let (kind, id) = Self.split(argument)
        switch (kind, id) {
        case ("inbox", nil): screen = .inbox
        case ("macs", nil): screen = .macs
        case ("session", let id?): screen = .session(id)
        case ("terminal", let id?): screen = .terminal(id, fitsPhone: false)
        case ("terminal-fit", let id?): screen = .terminal(id, fitsPhone: true)
        default: screen = .inbox
        }
    }

    private static func split(_ argument: String) -> (String, String?) {
        guard let colon = argument.firstIndex(of: ":") else { return (argument, nil) }
        return (String(argument[..<colon]), String(argument[argument.index(after: colon)...]))
    }
}
