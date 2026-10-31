import Foundation
import Observation

public protocol HistoryStoring: Sendable {
    func recentHistory(limit: Int) async throws -> [HistoryEntry]
    func searchHistory(_ query: String, limit: Int) async throws -> [HistoryEntry]
    func deleteHistory(url: URL) async throws
    func clearHistory() async throws
}

@MainActor
@Observable
public final class HistoryModel {
    public private(set) var entries: [HistoryEntry] = []
    public var query = "" {
        didSet { Task { await reload() } }
    }

    private static let limit = 500
    @ObservationIgnored private let store: (any HistoryStoring)?

    public init(store: (any HistoryStoring)?) {
        self.store = store
    }

    public func reload() async {
        guard let store else { return }
        let text = query.trimmingCharacters(in: .whitespaces)
        let loaded = try? await text.isEmpty
            ? store.recentHistory(limit: Self.limit)
            : store.searchHistory(text, limit: Self.limit)
        // A slower, older search must not overwrite the newer query's result.
        if let loaded, text == query.trimmingCharacters(in: .whitespaces) { entries = loaded }
    }

    public func delete(_ entry: HistoryEntry) async {
        try? await store?.deleteHistory(url: entry.url)
        await reload()
    }

    public func clear() async {
        try? await store?.clearHistory()
        await reload()
    }
}
