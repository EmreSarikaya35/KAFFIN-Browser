import Foundation
import Observation

public struct Suggestion: Sendable, Equatable, Identifiable {
    public enum Kind: Sendable {
        case site
        case search
        case address
        case bookmark
        case history
    }

    public let kind: Kind
    public let title: String
    public let detail: String
    public let url: URL
    /// Text to complete in the address bar. Set only on the row Enter opens by default.
    public let completion: String?

    public var id: URL { url }

    init(kind: Kind, title: String, detail: String, url: URL, completion: String? = nil) {
        self.kind = kind
        self.title = title
        self.detail = detail
        self.url = url
        self.completion = completion
    }
}

public struct InlineCompletion: Sendable, Equatable {
    public let typed: String
    public let text: String

    public init(typed: String, text: String) {
        self.typed = typed
        self.text = text
    }
}

public enum SuggestionRanker {
    public static func rank(
        query: String,
        bookmarks: [BookmarkItem],
        history: [HistoryEntry],
        sites: [SiteMatch] = [],
        engine: SearchEngine,
        limit: Int
    ) -> [Suggestion] {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return [] }

        var rows: [Suggestion] = []
        if let best = bestSite(for: text, bookmarks: bookmarks, sites: sites, history: history) { rows.append(best) }
        let searchURL = engine.url(for: text)
        if let address = AddressResolver.resolve(text, searchEngine: engine), address != searchURL,
           !rows.contains(where: { $0.url == address }) {
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

    /// Only a bare start of a site name completes. Phrases and full addresses mean what was typed.
    private static func bestSite(
        for text: String,
        bookmarks: [BookmarkItem],
        sites: [SiteMatch],
        history: [HistoryEntry]
    ) -> Suggestion? {
        guard text.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }) else { return nil }
        for site in sites {
            if let completed = complete(typed: text, host: site.host) {
                let pageTitle = history.first { $0.url == site.url }?.title ?? ""
                return Suggestion(kind: .site, title: site.host, detail: pageTitle, url: site.url, completion: completed)
            }
        }
        for item in bookmarks {
            if let host = SiteMatch.siteHost(of: item.url), let completed = complete(typed: text, host: host) {
                let detail = AddressDisplay.text(for: item.url)
                return Suggestion(kind: .bookmark, title: item.title, detail: detail, url: item.url, completion: completed)
            }
        }
        return nil
    }

    /// Keeps the typed letters as they are, and adds the rest of the site's name.
    public static func complete(typed: String, host: String) -> String? {
        let lowered = typed.lowercased()
        if host.hasPrefix(lowered) { return typed + host.dropFirst(typed.count) }
        let full = "www.\(host)"
        return full.hasPrefix(lowered) ? typed + full.dropFirst(typed.count) : nil
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
    public private(set) var inlineCompletion: InlineCompletion?
    private var defaultRowTyped: String?

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

    /// The row Enter opens when no row was chosen with the arrows.
    /// It must belong to the current text, or a slow lookup could send Enter to an old result.
    public func defaultSuggestion(for text: String) -> Suggestion? {
        guard let row = items.first, let completion = row.completion, let defaultRowTyped else { return nil }
        return text == defaultRowTyped || text == completion ? row : nil
    }

    /// Pass false after a deletion, so Enter keeps exactly what is left in the field.
    public func update(text: String, engine: SearchEngine, allowsCompletion: Bool = true) async {
        generation += 1
        let current = generation
        let found = (try? await history?.searchHistory(text, limit: 20)) ?? []
        var prefix = text.lowercased()
        if prefix.hasPrefix("www.") { prefix.removeFirst(4) }
        let sites = allowsCompletion ? (try? await history?.topSites(matching: prefix, limit: 3)) ?? [] : []
        guard current == generation else { return }

        let rows = SuggestionRanker.rank(
            query: text,
            bookmarks: bookmarks(),
            history: found,
            sites: sites,
            engine: engine,
            limit: Self.limit
        )
        items = rows
        selectedIndex = nil
        let completion = allowsCompletion ? rows.first?.completion : nil
        defaultRowTyped = completion == nil ? nil : text
        inlineCompletion = completion.map { InlineCompletion(typed: text, text: $0) }
    }

    /// The row the list highlights, which is what Enter will open.
    public func isHighlighted(_ item: Suggestion) -> Bool {
        selected == item || (selected == nil && defaultRowTyped != nil && items.first == item)
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
        defaultRowTyped = nil
        inlineCompletion = nil
    }
}
