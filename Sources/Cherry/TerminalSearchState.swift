import AppKit
import Foundation

@MainActor
protocol TerminalFindPasteboard: AnyObject {
    var string: String? { get set }
}

@MainActor
final class SystemTerminalFindPasteboard: TerminalFindPasteboard {
    static let shared = SystemTerminalFindPasteboard()

    private let pasteboard = NSPasteboard(name: .find)

    private init() {}

    var string: String? {
        get {
            pasteboard.string(forType: .string)
        }
        set {
            pasteboard.clearContents()
            if let newValue {
                pasteboard.setString(newValue, forType: .string)
            }
        }
    }
}

@MainActor
final class TerminalSearchState: ObservableObject {
    @Published var query: String = ""
    @Published private(set) var totalMatchCount: Int?
    @Published private(set) var selectedMatchIndex: Int?
    @Published var selectsQueryOnNextFocus = false

    private let pasteboard: TerminalFindPasteboard

    init(pasteboard: TerminalFindPasteboard = SystemTerminalFindPasteboard.shared) {
        self.pasteboard = pasteboard
        readQueryFromPasteboard()
    }

    var resultCountDescription: String? {
        if let selectedMatchIndex {
            let total = totalMatchCount.map(String.init) ?? "?"
            return "\(selectedMatchIndex + 1)/\(total)"
        }

        if let totalMatchCount {
            return "-/\(totalMatchCount)"
        }

        return nil
    }

    func readQueryFromPasteboard() {
        guard let pasteboardQuery = pasteboard.string,
              pasteboardQuery != query
        else { return }

        query = pasteboardQuery
        selectsQueryOnNextFocus = true
    }

    func writeQueryToPasteboard() {
        pasteboard.string = query
    }

    func update(total: Int?) {
        totalMatchCount = total
        if total == nil {
            selectedMatchIndex = nil
        }
    }

    func update(selected: Int?) {
        selectedMatchIndex = selected
    }

    func consumeSelectsQueryOnNextFocus() -> Bool {
        guard selectsQueryOnNextFocus else { return false }
        selectsQueryOnNextFocus = false
        return true
    }
}
