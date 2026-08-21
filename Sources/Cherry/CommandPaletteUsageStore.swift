import Combine
import Foundation

@MainActor
final class CommandPaletteUsageStore: ObservableObject {
    struct Entry: Codable, Equatable {
        var selectionCount: Int
        var lastSelectedAt: Date
    }

    static let shared = CommandPaletteUsageStore()

    @Published private(set) var entries: [String: Entry]

    private let defaults: UserDefaults
    private let storageKey: String

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "commandPalette.usage.v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey

        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        else {
            entries = [:]
            return
        }
        entries = decoded
    }

    func recordSelection(id: String, at date: Date = Date()) {
        guard !id.isEmpty else { return }

        var entry = entries[id] ?? Entry(selectionCount: 0, lastSelectedAt: date)
        entry.selectionCount = min(entry.selectionCount + 1, 10_000)
        entry.lastSelectedAt = date
        entries[id] = entry

        if entries.count > 200 {
            let retained = entries
                .sorted { $0.value.lastSelectedAt > $1.value.lastSelectedAt }
                .prefix(200)
            entries = Dictionary(uniqueKeysWithValues: retained.map { ($0.key, $0.value) })
        }

        persist()
    }

    func rankingScores(at date: Date = Date()) -> [String: Int] {
        entries.mapValues { entry in
            let frequency = min(
                120,
                Int(log2(Double(entry.selectionCount) + 1) * 28)
            )
            let age = max(0, date.timeIntervalSince(entry.lastSelectedAt))
            let recency: Int
            switch age {
            case ..<3_600:
                recency = 80
            case ..<86_400:
                recency = 60
            case ..<604_800:
                recency = 35
            case ..<2_592_000:
                recency = 15
            default:
                recency = 0
            }
            return frequency + recency
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
