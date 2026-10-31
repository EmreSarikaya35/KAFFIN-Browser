import Foundation
import Observation

public struct Suggestion: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable {
        case search
        case address
        case bookmark
        case history
    }

    public let kind: Kind
    public let title: String
    public let detail: String
    public let url: URL

    public var id: URL { url }
}

public enum SuggestionRanker {
    public static func rank(
        query: String,
        bookmarks: [BookmarkItem],
        history: [HistoryEntry],
        engine: SearchEngine,
        limit: Int
    ) -> [Suggestion] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        var rows: [Suggestion] = []
        let searchURL = engine.url(for: text)
        if let address = AddressResolver.resolve(text, searchEngine: engine), address != searchURL {
            rows.append(Suggestion(kind: .address, title: text, detail: "", url: address))
        }
        if let searchURL {
            let detail = String(format: L10n.string("suggestion.search"), engine.name)
            rows.append(Suggestion(kind: .search, title: text, detail: detail, url: searchURL))
        }

        let folded = fold(text)
        var scored: [(score: Double, visits: Int, suggestion: Suggestion)] = []
        var seen = Set(rows.map(\.url))
        for item in bookmarks {
            let score = score(url: item.url, title: item.title, query: folded)
            if score > 0, seen.insert(item.url).inserted {
                let row = Suggestion(kind: .bookmark, title: item.title, detail: AddressDisplay.text(for: item.url), url: item.url)
                scored.append((score + 0.5, 0, row))
            }
        }
        for entry in history {
            let score = score(url: entry.url, title: entry.title, query: folded)
            if score > 0, seen.insert(entry.url).inserted {
                let detail = AddressDisplay.text(for: entry.url)
                let row = Suggestion(kind: .history, title: entry.title ?? detail, detail: detail, url: entry.url)
                scored.append((score, entry.visitCount, row))
            }
        }
        scored.sort { ($0.score, $0.visits) > ($1.score, $1.visits) }
        return Array((rows + scored.map(\.suggestion)).prefix(limit))
    }

    /// 0 means no match. A site's own name outranks a page that merely mentions the words.
    private static func score(url: URL, title: String?, query: String) -> Double {
        var host = fold(url.host() ?? "")
        if host.hasPrefix("www.") { host.removeFirst(4) }
        if host.hasPrefix(query) { return 3 }

        let title = fold(title ?? "")
        if title.split(separator: " ").contains(where: { $0.hasPrefix(query) }) { return 2 }
        return title.contains(query) || fold(url.absoluteString).contains(query) ? 1 : 0
    }

    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .replacingOccurrences(of: "ı", with: "i")
    }
}

@MainActor
@Observable
public final class SuggestionsModel {
    public private(set) var items: [Suggestion] = []
    private var selectedIndex: Int?

    private static let limit = 6
    @ObservationIgnored private let history: (any HistoryStoring)?
    @ObservationIgnored private let bookmarks: @MainActor () -> [BookmarkItem]
    @ObservationIgnored private var generation = 0

    /// Pass no history for private windows, so typing there never reads the profile's browsing record.
    public init(history: (any HistoryStoring)?, bookmarks: @escaping @MainActor () -> [BookmarkItem]) {
        self.history = history
        self.bookmarks = bookmarks
    }

    public var selected: Suggestion? {
        selectedIndex.flatMap { items.indices.contains($0) ? items[$0] : nil }
    }

    public func update(text: String, engine: SearchEngine) async {
        generation += 1
        let current = generation
        let found = (try? await history?.searchHistory(text, limit: 20)) ?? []
        guard current == generation else { return }
        items = SuggestionRanker.rank(
            query: text,
            bookmarks: bookmarks(),
            history: found,
            engine: engine,
            limit: Self.limit
        )
        selectedIndex = nil
    }

    /// Position 0 is the typed text itself, so the arrows can always return to it.
    public func move(by delta: Int) {
        let count = items.count + 1
        let position = ((selectedIndex.map { $0 + 1 } ?? 0) + delta + count) % count
        selectedIndex = position == 0 ? nil : position - 1
    }

    public func clear() {
        generation += 1
        items = []
        selectedIndex = nil
    }
}
