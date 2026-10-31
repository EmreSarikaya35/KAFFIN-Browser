import BrowserCore
import Foundation
import GRDB
@testable import Persistence
import Testing

struct ProfileDatabaseTests {
    private let example = URL(string: "https://example.com/a")!
    private let other = URL(string: "https://swift.org/")!

    @Test func repeatVisitsCountOnceWithLatestTitle() async throws {
        let db = try ProfileDatabase.inMemory()
        try await db.recordVisit(url: example, title: "Old", at: Date(timeIntervalSince1970: 1))
        try await db.recordVisit(url: example, title: "New", at: Date(timeIntervalSince1970: 2))

        let entries = try await db.recentHistory(limit: 10)
        #expect(entries.count == 1)
        #expect(entries[0].title == "New")
        #expect(entries[0].visitCount == 2)
        #expect(entries[0].lastVisit == Date(timeIntervalSince1970: 2))
    }

    @Test func titleArrivingAfterVisitFillsEntry() async throws {
        let db = try ProfileDatabase.inMemory()
        try await db.recordVisit(url: example, title: nil, at: .now)
        try await db.updateHistoryTitle(url: example, title: "Late Title")

        #expect(try await db.recentHistory(limit: 1).first?.title == "Late Title")
    }

    @Test func titleForUnvisitedPageCreatesNothing() async throws {
        let db = try ProfileDatabase.inMemory()
        try await db.updateHistoryTitle(url: example, title: "Never Visited")
        #expect(try await db.recentHistory(limit: 1).isEmpty)
    }

    @Test func revisitWithoutTitleKeepsKnownTitle() async throws {
        let db = try ProfileDatabase.inMemory()
        try await db.recordVisit(url: example, title: "Known", at: .now)
        try await db.recordVisit(url: example, title: "", at: .now)

        #expect(try await db.recentHistory(limit: 1).first?.title == "Known")
    }

    @Test func historyIgnoresNonWebPages() async throws {
        let db = try ProfileDatabase.inMemory()
        try await db.recordVisit(url: URL(string: "about:blank")!, title: nil, at: .now)
        #expect(try await db.recentHistory(limit: 10).isEmpty)
    }

    @Test func recentHistoryIsNewestFirst() async throws {
        let db = try ProfileDatabase.inMemory()
        try await db.recordVisit(url: example, title: nil, at: Date(timeIntervalSince1970: 1))
        try await db.recordVisit(url: other, title: nil, at: Date(timeIntervalSince1970: 2))

        #expect(try await db.recentHistory(limit: 1).map(\.url) == [other])
    }

    @Test func searchMatchesTitleAndAddressWithLiteralWildcards() async throws {
        let db = try ProfileDatabase.inMemory()
        try await db.recordVisit(url: example, title: "Kahve Rehberi", at: .now)
        try await db.recordVisit(url: other, title: "100% Swift", at: .now)

        #expect(try await db.searchHistory("kahve", limit: 10).map(\.url) == [example])
        #expect(try await db.searchHistory("swift.org", limit: 10).map(\.url) == [other])
        #expect(try await db.searchHistory("%", limit: 10).map(\.url) == [other])
    }

    @Test func deletingAndClearingHistoryRemovesVisits() async throws {
        let db = try ProfileDatabase.inMemory()
        try await db.recordVisit(url: example, title: nil, at: .now)
        try await db.recordVisit(url: other, title: nil, at: .now)

        try await db.deleteHistory(url: example)
        #expect(try await db.recentHistory(limit: 10).map(\.url) == [other])
        #expect(try await db.visitCount() == 1)

        try await db.clearHistory()
        #expect(try await db.recentHistory(limit: 10).isEmpty)
        #expect(try await db.visitCount() == 0)
    }

    @Test func bookmarksKeepOrderAndIgnoreDuplicates() async throws {
        let db = try ProfileDatabase.inMemory()
        try await db.addBookmark(url: example, title: "A")
        try await db.addBookmark(url: other, title: "B")
        try await db.addBookmark(url: example, title: "A again")

        #expect(try await db.bookmarks() == [
            BookmarkItem(url: example, title: "A"),
            BookmarkItem(url: other, title: "B"),
        ])

        try await db.removeBookmark(url: example)
        #expect(try await db.bookmarks().map(\.url) == [other])
    }

    @Test func sessionRoundTripsAndReplacesPreviousSession() async throws {
        let db = try ProfileDatabase.inMemory()
        let state = Data([1, 2, 3])
        let windows = [
            SessionWindow(tabs: [
                SessionTab(url: example, title: "A", isSelected: false, interactionState: state),
                SessionTab(url: other, title: nil, isSelected: true, interactionState: nil, isPinned: true),
            ]),
            SessionWindow(tabs: [SessionTab(url: other, title: "B", isSelected: true, interactionState: nil)]),
        ]

        try await db.saveSession(windows)
        #expect(try await db.loadSession() == windows)

        try await db.saveSession([windows[1]])
        #expect(try await db.loadSession() == [windows[1]])
    }

    @Test func sitesAddUpAllPagesAndIgnoreWww() async throws {
        let db = try ProfileDatabase.inMemory()
        try await db.recordVisit(url: URL(string: "https://www.youtube.com/a")!, title: nil, at: .now)
        try await db.recordVisit(url: URL(string: "https://www.youtube.com/b")!, title: nil, at: .now)
        try await db.recordVisit(url: URL(string: "https://www.youtube.com/b")!, title: nil, at: .now)
        try await db.recordVisit(url: URL(string: "https://yandex.com/")!, title: nil, at: .now)

        let sites = try await db.topSites(matching: "y", limit: 5)
        #expect(sites.map(\.host) == ["youtube.com", "yandex.com"])
        #expect(sites.map(\.visits) == [3, 1])
        #expect(sites[0].url.absoluteString == "https://www.youtube.com/")
    }

    @Test func siteSearchMatchesOnlyStartOfHostAndTreatsWildcardsLiterally() async throws {
        let db = try ProfileDatabase.inMemory()
        try await db.recordVisit(url: URL(string: "https://example.com/")!, title: nil, at: .now)

        #expect(try await db.topSites(matching: "ample", limit: 5).isEmpty)
        #expect(try await db.topSites(matching: "%", limit: 5).isEmpty)
        #expect(try await db.topSites(matching: "EX", limit: 5).map(\.host) == ["example.com"])
    }

    @Test func historyFromBeforeSiteColumnIsBackfilled() async throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "kaffin-\(UUID()).sqlite").path(percentEncoded: false)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let queue = try DatabaseQueue(path: path)
        try ProfileDatabase.migrator.migrate(queue, upTo: "v2")
        try await queue.write { db in
            try db.execute(
                sql: "INSERT INTO historyURLs (url, visitCount, lastVisit) VALUES (?, 1, ?)",
                arguments: ["https://www.youtube.com/watch", Date()]
            )
        }
        try queue.close()

        let sites = try await ProfileDatabase(path: path).topSites(matching: "you", limit: 5)
        #expect(sites.map(\.host) == ["youtube.com"])
    }

    @Test func faviconsPersistByHost() async throws {
        let db = try ProfileDatabase.inMemory()
        try await db.saveFavicon(host: "example.com", data: Data([1]))
        try await db.saveFavicon(host: "example.com", data: Data([2]))

        #expect(try await db.favicon(host: "example.com") == Data([2]))
        #expect(try await db.favicon(host: "other.example") == nil)
    }

    // The real path contains "Application Support", so the space matters.
    @Test func dataSurvivesReopeningFile() async throws {
        let folder = FileManager.default.temporaryDirectory.appending(path: "kaffin test \(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let path = folder.appending(path: "profile.sqlite").path(percentEncoded: false)

        try await ProfileDatabase(path: path).addBookmark(url: example, title: "A")
        #expect(try await ProfileDatabase(path: path).bookmarks().map(\.title) == ["A"])
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "profile.sqlite").path(percentEncoded: false)))
    }
}

@MainActor
struct SuggestionsModelTests {
    private func makeModel() async throws -> (SuggestionsModel, ProfileDatabase) {
        let db = try ProfileDatabase.inMemory()
        try await db.recordVisit(url: URL(string: "https://swift.org/")!, title: "Swift", at: .now)
        return (SuggestionsModel(history: db, bookmarks: { [] }), db)
    }

    @Test func findsVisitedSiteWithItsPageTitle() async throws {
        let (model, _) = try await makeModel()
        await model.update(text: "swift", engine: .google)
        #expect(model.items.first?.kind == .site)
        #expect(model.items.first?.title == "swift.org")
        #expect(model.items.first?.detail == "Swift")
    }

    @Test func findsPagesByTitleToo() async throws {
        let db = try ProfileDatabase.inMemory()
        try await db.recordVisit(url: URL(string: "https://example.com/rehber")!, title: "Kahve Rehberi", at: .now)
        let model = SuggestionsModel(history: db, bookmarks: { [] })

        await model.update(text: "kahve", engine: .google)
        #expect(model.items.contains { $0.kind == .history && $0.title == "Kahve Rehberi" })
    }

    /// Holds the lookup for "s" until released, so the old result really arrives last.
    private actor GatedHistory: HistoryStoring {
        private var waiting: CheckedContinuation<Void, Never>?
        private(set) var isWaiting = false

        func release() {
            waiting?.resume()
            waiting = nil
        }

        func searchHistory(_ query: String, limit: Int) async -> [HistoryEntry] {
            if query == "s" {
                await withCheckedContinuation { waiting = $0; isWaiting = true }
            }
            return []
        }

        func topSites(matching prefix: String, limit: Int) -> [SiteMatch] {
            let host = prefix == "s" ? "stale.example" : "swift.org"
            return [SiteMatch(url: URL(string: "https://\(host)/")!, host: host, visits: 1)]
        }

        func recentHistory(limit: Int) -> [HistoryEntry] { [] }
        func deleteHistory(url: URL) {}
        func clearHistory() {}
    }

    @Test func staleResultCannotReplaceNewerText() async throws {
        let history = GatedHistory()
        let model = SuggestionsModel(history: history, bookmarks: { [] })

        let older = Task { await model.update(text: "s", engine: .google) }
        while await !history.isWaiting { await Task.yield() }

        await model.update(text: "sw", engine: .google)
        await history.release()
        await older.value

        #expect(model.inlineCompletion == InlineCompletion(typed: "sw", text: "swift.org"))
        #expect(model.items.first?.url.host() == "swift.org")
    }

    @Test func typingFirstLetterOffersMostVisitedSite() async throws {
        let db = try ProfileDatabase.inMemory()
        for page in 0..<5 {
            try await db.recordVisit(url: URL(string: "https://www.youtube.com/watch?v=\(page)")!, title: "Video \(page)", at: .now)
        }
        try await db.recordVisit(url: URL(string: "https://yahoo.com/")!, title: "Yahoo", at: .now)
        let model = SuggestionsModel(history: db, bookmarks: { [] })

        await model.update(text: "y", engine: .google)

        #expect(model.items.first?.url.absoluteString == "https://www.youtube.com/")
        #expect(model.inlineCompletion == InlineCompletion(typed: "y", text: "youtube.com"))
        #expect(model.defaultSuggestion(for: "y") == model.items.first)
        #expect(model.defaultSuggestion(for: "youtube.com") == model.items.first)
    }

    @Test func deletingTurnsCompletionOffSoEnterKeepsTypedText() async throws {
        let (model, _) = try await makeModel()
        await model.update(text: "sw", engine: .google, allowsCompletion: false)

        #expect(model.inlineCompletion == nil)
        #expect(model.defaultSuggestion(for: "sw") == nil)
    }

    @Test func rowsFromOlderTextAreNeverTheEnterTarget() async throws {
        let (model, _) = try await makeModel()
        await model.update(text: "s", engine: .google)
        #expect(model.defaultSuggestion(for: "sw") == nil)
    }

    @Test func arrowKeysWrapThroughRowsAndBackToTypedText() async throws {
        let (model, _) = try await makeModel()
        await model.update(text: "swift", engine: .google)
        let count = model.items.count

        #expect(model.selected == nil)
        model.move(by: 1)
        #expect(model.selected == model.items[0])
        model.move(by: -1)
        #expect(model.selected == nil)
        model.move(by: -1)
        #expect(model.selected == model.items[count - 1])
    }

    @Test func clearingHidesRowsAndDropsLateResults() async throws {
        let (model, _) = try await makeModel()
        await model.update(text: "swift", engine: .google)
        model.clear()
        #expect(model.items.isEmpty)
        #expect(model.selected == nil)
    }

    @Test func privateWindowsSearchNoHistory() async {
        let model = SuggestionsModel(history: nil, bookmarks: { [] })
        await model.update(text: "swift", engine: .google)
        #expect(model.items.map(\.kind) == [.search])
    }
}

@MainActor
struct BookmarksModelTests {
    @Test func toggleAddsThenRemovesAndUsesHostWhenUntitled() async throws {
        let model = BookmarksModel(store: try ProfileDatabase.inMemory())
        let url = URL(string: "https://example.com/a")!

        await model.toggle(url: url, title: nil)
        #expect(model.items == [BookmarkItem(url: url, title: "example.com")])
        #expect(model.contains(url))

        await model.toggle(url: url, title: nil)
        #expect(model.items.isEmpty)
    }
}
