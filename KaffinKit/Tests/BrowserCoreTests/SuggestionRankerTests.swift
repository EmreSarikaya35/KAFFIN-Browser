import BrowserCore
import Foundation
import Testing

struct SuggestionRankerTests {
    private func entry(_ url: String, _ title: String?, visits: Int = 1) -> HistoryEntry {
        HistoryEntry(url: URL(string: url)!, title: title, visitCount: visits, lastVisit: .now)
    }

    @Test func plainWordsStartWithSearch() {
        let rows = SuggestionRanker.rank(query: "kahve", bookmarks: [], history: [], engine: .google, limit: 6)
        #expect(rows.first?.kind == .search)
        #expect(rows.first?.url.absoluteString == "https://www.google.com/search?q=kahve")
    }

    @Test func addressStartsWithDirectRowThenSearch() {
        let rows = SuggestionRanker.rank(query: "example.com", bookmarks: [], history: [], engine: .google, limit: 6)
        #expect(rows.map(\.kind) == [.address, .search])
        #expect(rows[0].url.absoluteString == "https://example.com")
    }

    @Test func siteStartingWithQueryBeatsPageMentioningIt() {
        let rows = SuggestionRanker.rank(
            query: "git",
            bookmarks: [],
            history: [
                entry("https://example.com/a", "Git tutorial", visits: 50),
                entry("https://www.github.com/", "GitHub", visits: 1),
            ],
            engine: .google,
            limit: 6
        ).filter { $0.kind != .search }
        #expect(rows.map(\.url.host) == ["www.github.com", "example.com"])
    }

    @Test func bookmarkWinsTieAndAppearsOnce() {
        let url = "https://swift.org/docs"
        let rows = SuggestionRanker.rank(
            query: "swift",
            bookmarks: [BookmarkItem(url: URL(string: url)!, title: "Swift Docs")],
            history: [entry(url, "Swift Docs", visits: 9), entry("https://swift.org/blog", "Swift Blog", visits: 9)],
            engine: .google,
            limit: 6
        ).filter { $0.kind != .search }
        #expect(rows.map(\.kind) == [.bookmark, .history])
        #expect(rows.map(\.url.absoluteString) == [url, "https://swift.org/blog"])
    }

    @Test func nonMatchingBookmarksStayOut() {
        let rows = SuggestionRanker.rank(
            query: "zzz",
            bookmarks: [BookmarkItem(url: URL(string: "https://swift.org")!, title: "Swift")],
            history: [],
            engine: .google,
            limit: 6
        )
        #expect(rows.map(\.kind) == [.search])
    }

    @Test func respectsLimitAndMatchesTurkishLetters() {
        let history = (0..<9).map { entry("https://site\($0).example/", "İstanbul \($0)") }
        let rows = SuggestionRanker.rank(query: "istanbul", bookmarks: [], history: history, engine: .google, limit: 4)
        #expect(rows.count == 4)
        #expect(rows.filter { $0.kind == .history }.count == 3)
    }

    @Test func blankQueryHasNoRows() {
        #expect(SuggestionRanker.rank(query: "  ", bookmarks: [], history: [], engine: .google, limit: 6).isEmpty)
    }
}
