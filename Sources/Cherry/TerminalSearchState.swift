import AppKit
import Foundation

@MainActor
final class TerminalSearchState: ObservableObject {
    @Published var query: String = ""
    @Published private(set) var totalMatchCount: Int?
    @Published private(set) var selectedMatchIndex: Int?
    @Published var selectsQueryOnNextFocus = false

    /// The find pasteboard the query is shared through, as other apps'
    /// Find; tests pass a private one.
    private let pasteboard: NSPasteboard

    init(pasteboard: NSPasteboard = NSPasteboard(name: .find)) {
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
        guard let pasteboardQuery = pasteboard.string(forType: .string),
              pasteboardQuery != query
        else { return }

        query = pasteboardQuery
        selectsQueryOnNextFocus = true
    }

    func writeQueryToPasteboard() {
        pasteboard.clearContents()
        pasteboard.setString(query, forType: .string)
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
