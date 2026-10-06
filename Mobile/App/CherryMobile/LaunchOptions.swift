import Foundation

/// Launch arguments for screenshots and demos (`Mobile/Scripts/screenshots`):
/// `-screen inbox`, `-screen session:<id>`, `-screen terminal:<id>`,
/// `-screen terminal-fit:<id>` or `-screen macs` opens that screen against
/// the Demo Mac. A run with `-screen` uses only the Demo Mac and connects
/// nowhere else.
struct LaunchOptions: Equatable, Sendable {
    enum Screen: Equatable, Sendable {
        case inbox
        case session(String)
        case terminal(String, fitsPhone: Bool)
        case macs
    }

    var screen: Screen?

    /// Only the Demo Mac: saved Macs are neither shown nor connected.
    var demoOnly: Bool {
        screen != nil
    }

    static var current: LaunchOptions {
        LaunchOptions(argument: UserDefaults.standard.string(forKey: "screen"))
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
