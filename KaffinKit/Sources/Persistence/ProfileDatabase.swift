import BrowserCore
import Foundation
import GRDB

/// One profile's local data. Keeps SQL out of every other module.
public final class ProfileDatabase: BookmarkStoring, HistoryStoring {
    private let writer: any DatabaseWriter

    /// Opens or creates the file, and applies pending migrations.
    public convenience init(path: String) throws {
        try self.init(writer: DatabasePool(path: path))
    }

    public static func inMemory() throws -> ProfileDatabase {
        try ProfileDatabase(writer: DatabaseQueue())
    }

    private init(writer: any DatabaseWriter) throws {
        self.writer = writer
        try Self.migrator.migrate(writer)
    }

    private static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "historyURLs") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("url", .text).notNull().unique()
                t.column("title", .text)
                t.column("visitCount", .integer).notNull()
                t.column("lastVisit", .datetime).notNull().indexed()
            }
            try db.create(table: "historyVisits") { t in
                t.autoIncrementedPrimaryKey("id")
                t.belongsTo("historyURL", onDelete: .cascade).notNull()
                t.column("visitedAt", .datetime).notNull().indexed()
            }
            try db.create(table: "bookmarks") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("url", .text).notNull().unique()
                t.column("title", .text).notNull()
            }
            try db.create(table: "sessionTabs") { t in
                t.column("windowIndex", .integer).notNull()
                t.column("position", .integer).notNull()
                t.column("url", .text).notNull()
                t.column("title", .text)
                t.column("isSelected", .boolean).notNull()
                t.column("interactionState", .blob)
                t.primaryKey(["windowIndex", "position"])
            }
        }
        return migrator
    }

    // MARK: History

    public func recordVisit(url: URL, title: String?, at date: Date) async throws {
        guard url.scheme == "http" || url.scheme == "https" else { return }
        let address = url.absoluteString
        try await writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO historyURLs (url, title, visitCount, lastVisit) VALUES (?, ?, 1, ?)
                ON CONFLICT(url) DO UPDATE SET
                    title = COALESCE(excluded.title, title),
                    visitCount = visitCount + 1,
                    lastVisit = excluded.lastVisit
                """,
                arguments: [address, title, date]
            )
            try db.execute(
                sql: "INSERT INTO historyVisits (historyURLId, visitedAt) SELECT id, ? FROM historyURLs WHERE url = ?",
                arguments: [date, address]
            )
        }
    }

    public func recentHistory(limit: Int) async throws -> [HistoryEntry] {
        try await writer.read { db in
            try Self.entries(
                db,
                sql: "SELECT * FROM historyURLs ORDER BY lastVisit DESC, id DESC LIMIT ?",
                arguments: [limit]
            )
        }
    }

    public func searchHistory(_ query: String, limit: Int) async throws -> [HistoryEntry] {
        let escaped = query
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        let pattern = "%\(escaped)%"
        return try await writer.read { db in
            try Self.entries(
                db,
                sql: """
                SELECT * FROM historyURLs
                WHERE url LIKE ? ESCAPE '\\' OR title LIKE ? ESCAPE '\\'
                ORDER BY visitCount DESC, lastVisit DESC LIMIT ?
                """,
                arguments: [pattern, pattern, limit]
            )
        }
    }

    public func deleteHistory(url: URL) async throws {
        let address = url.absoluteString
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM historyURLs WHERE url = ?", arguments: [address])
        }
    }

    public func clearHistory() async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM historyURLs")
        }
    }

    public func visitCount() async throws -> Int {
        try await writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM historyVisits") ?? 0
        }
    }

    private static func entries(_ db: Database, sql: String, arguments: StatementArguments) throws -> [HistoryEntry] {
        try Row.fetchAll(db, sql: sql, arguments: arguments).compactMap { row in
            guard let url = URL(string: row["url"]) else { return nil }
            return HistoryEntry(url: url, title: row["title"], visitCount: row["visitCount"], lastVisit: row["lastVisit"])
        }
    }

    // MARK: Bookmarks

    public func addBookmark(url: URL, title: String) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "INSERT INTO bookmarks (url, title) VALUES (?, ?) ON CONFLICT(url) DO NOTHING",
                arguments: [url.absoluteString, title]
            )
        }
    }

    public func removeBookmark(url: URL) async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM bookmarks WHERE url = ?", arguments: [url.absoluteString])
        }
    }

    public func bookmarks() async throws -> [BookmarkItem] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: "SELECT url, title FROM bookmarks ORDER BY id").compactMap { row in
                URL(string: row["url"]).map { BookmarkItem(url: $0, title: row["title"]) }
            }
        }
    }

    // MARK: Session

    public func saveSession(_ windows: [SessionWindow]) async throws {
        try await writer.write { try Self.replaceSession(windows, in: $0) }
    }

    /// For app termination, when no async work can finish.
    public func saveSessionBlocking(_ windows: [SessionWindow]) throws {
        try writer.write { try Self.replaceSession(windows, in: $0) }
    }

    private static func replaceSession(_ windows: [SessionWindow], in db: Database) throws {
        try db.execute(sql: "DELETE FROM sessionTabs")
        for (windowIndex, window) in windows.enumerated() {
            for (position, tab) in window.tabs.enumerated() {
                try db.execute(
                    sql: """
                    INSERT INTO sessionTabs (windowIndex, position, url, title, isSelected, interactionState)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [windowIndex, position, tab.url.absoluteString, tab.title, tab.isSelected, tab.interactionState]
                )
            }
        }
    }

    public func loadSession() async throws -> [SessionWindow] {
        try await writer.read { db in
            var windows: [Int: [SessionTab]] = [:]
            for row in try Row.fetchAll(db, sql: "SELECT * FROM sessionTabs ORDER BY windowIndex, position") {
                guard let url = URL(string: row["url"]) else { continue }
                let tab = SessionTab(
                    url: url,
                    title: row["title"],
                    isSelected: row["isSelected"],
                    interactionState: row["interactionState"]
                )
                windows[row["windowIndex"], default: []].append(tab)
            }
            return windows.keys.sorted().compactMap { windows[$0].map(SessionWindow.init) }
        }
    }
}
