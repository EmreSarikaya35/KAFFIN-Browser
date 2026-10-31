import BrowserCore
import Foundation
import Persistence
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
                SessionTab(url: other, title: nil, isSelected: true, interactionState: nil),
            ]),
            SessionWindow(tabs: [SessionTab(url: other, title: "B", isSelected: true, interactionState: nil)]),
        ]

        try await db.saveSession(windows)
        #expect(try await db.loadSession() == windows)

        try await db.saveSession([windows[1]])
        #expect(try await db.loadSession() == [windows[1]])
    }

    @Test func dataSurvivesReopeningFile() async throws {
        let path = FileManager.default.temporaryDirectory.appending(path: "kaffin-\(UUID()).sqlite").path()
        defer { try? FileManager.default.removeItem(atPath: path) }

        try await ProfileDatabase(path: path).addBookmark(url: example, title: "A")
        #expect(try await ProfileDatabase(path: path).bookmarks().map(\.title) == ["A"])
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
