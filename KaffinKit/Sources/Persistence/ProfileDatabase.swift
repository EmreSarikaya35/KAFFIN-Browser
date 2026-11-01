import BrowserCore
import Foundation
import GRDB

/// One profile's local data. Keeps SQL out of every other module.
public final class ProfileDatabase: BookmarkStoring, HistoryStoring, FaviconStoring, SitePermissionStoring {
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

    static var migrator: DatabaseMigrator {
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
        migrator.registerMigration("v2") { db in
            try db.create(table: "favicons") { t in
                t.primaryKey("host", .text)
                t.column("data", .blob).notNull()
            }
        }
        migrator.registerMigration("v3") { db in
            try db.alter(table: "historyURLs") { t in t.add(column: "host", .text) }
            for row in try Row.fetchAll(db, sql: "SELECT id, url FROM historyURLs") {
                let host = URL(string: row["url"]).flatMap(SiteMatch.siteHost)
                try db.execute(sql: "UPDATE historyURLs SET host = ? WHERE id = ?", arguments: [host, row["id"]])
            }
            try db.create(index: "historyURLs_on_host", on: "historyURLs", columns: ["host"])
        }
        migrator.registerMigration("v4") { db in
            try db.alter(table: "sessionTabs") { t in
                t.add(column: "isPinned", .boolean).notNull().defaults(to: false)
            }
        }
        migrator.registerMigration("v5") { db in
            try db.create(table: "bookmarkFolders") { t in
                t.autoIncrementedPrimaryKey("id")
                t.column("title", .text).notNull()
                t.belongsTo("parent", inTable: "bookmarkFolders", onDelete: .cascade)
            }
            try db.alter(table: "bookmarks") { t in
                t.add(column: "folderId", .integer).references("bookmarkFolders", onDelete: .cascade)
            }
        }
        migrator.registerMigration("v6") { db in
            try db.create(table: "sitePermissions") { t in
                t.column("site", .text).notNull()
                t.column("kind", .text).notNull()
                t.column("isAllowed", .boolean).notNull()
                t.primaryKey(["site", "kind"])
            }
        }
        return migrator
    }

    // MARK: History

    public func recordVisit(url: URL, title: String?, at date: Date) async throws {
        guard url.scheme == "http" || url.scheme == "https" else { return }
        let address = url.absoluteString
        let title = title.flatMap { $0.isEmpty ? nil : $0 }
        try await writer.write { db in
            try db.execute(
                sql: """
                INSERT INTO historyURLs (url, title, visitCount, lastVisit, host) VALUES (?, ?, 1, ?, ?)
                ON CONFLICT(url) DO UPDATE SET
                    title = COALESCE(excluded.title, title),
                    visitCount = visitCount + 1,
                    lastVisit = excluded.lastVisit
                """,
                arguments: [address, title, date, SiteMatch.siteHost(of: url)]
            )
            try db.execute(
                sql: "INSERT INTO historyVisits (historyURLId, visitedAt) SELECT id, ? FROM historyURLs WHERE url = ?",
                arguments: [date, address]
            )
        }
    }

    /// Importing the same browser twice changes nothing, because counts keep the higher value instead of adding up.
    public func importHistory(_ entries: [HistoryEntry]) async throws -> Int {
        try await writer.write { db in
            let before = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM historyURLs") ?? 0
            for entry in entries {
                let address = entry.url.absoluteString
                try db.execute(
                    sql: """
                    INSERT INTO historyURLs (url, title, visitCount, lastVisit, host) VALUES (?, ?, ?, ?, ?)
                    ON CONFLICT(url) DO UPDATE SET
                        title = COALESCE(title, excluded.title),
                        visitCount = MAX(visitCount, excluded.visitCount),
                        lastVisit = MAX(lastVisit, excluded.lastVisit)
                    """,
                    arguments: [address, entry.title, entry.visitCount, entry.lastVisit, SiteMatch.siteHost(of: entry.url)]
                )
                try db.execute(
                    sql: """
                    INSERT INTO historyVisits (historyURLId, visitedAt)
                    SELECT id, ? FROM historyURLs WHERE url = ?
                    AND NOT EXISTS (SELECT 1 FROM historyVisits WHERE historyURLId = historyURLs.id)
                    """,
                    arguments: [entry.lastVisit, address]
                )
            }
            return (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM historyURLs") ?? 0) - before
        }
    }

    /// WebKit often delivers a page's title after the page finishes loading.
    public func updateHistoryTitle(url: URL, title: String) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE historyURLs SET title = ? WHERE url = ?",
                arguments: [title, url.absoluteString]
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
        let pattern = "%\(Self.escapeLike(query))%"
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

    public func topSites(matching prefix: String, limit: Int) async throws -> [SiteMatch] {
        let pattern = "\(Self.escapeLike(prefix.lowercased()))%"
        return try await writer.read { db in
            // With a single MAX, SQLite takes the bare url from the site's most visited page.
            try Row.fetchAll(
                db,
                sql: """
                SELECT host, url, SUM(visitCount) AS visits, MAX(visitCount)
                FROM historyURLs WHERE host LIKE ? ESCAPE '\\'
                GROUP BY host ORDER BY visits DESC LIMIT ?
                """,
                arguments: [pattern, limit]
            ).compactMap { row in
                guard let page = URL(string: row["url"]),
                      var root = URLComponents(url: page, resolvingAgainstBaseURL: false) else { return nil }
                root.path = "/"
                root.query = nil
                root.fragment = nil
                return root.url.map { SiteMatch(url: $0, host: row["host"], visits: row["visits"]) }
            }
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

    private static func escapeLike(_ text: String) -> String {
        text.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
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

    public func bookmarkTree() async throws -> BookmarkTree {
        try await writer.read { db in
            // Grouped first, so a large library is not rescanned once per folder.
            let folders = Dictionary(
                grouping: try Row.fetchAll(db, sql: "SELECT id, title, parentId FROM bookmarkFolders ORDER BY id")
            ) { row -> Int64? in row["parentId"] }
            let bookmarks = Dictionary(
                grouping: try Row.fetchAll(db, sql: "SELECT url, title, folderId FROM bookmarks ORDER BY id")
            ) { row -> Int64? in row["folderId"] }

            func node(id: Int64?, title: String) -> BookmarkTree {
                let items = (bookmarks[id] ?? []).compactMap { row -> BookmarkItem? in
                    URL(string: row["url"]).map { BookmarkItem(url: $0, title: row["title"]) }
                }
                let children = (folders[id] ?? []).map { node(id: $0["id"], title: $0["title"]) }
                return BookmarkTree(id: id, title: title, items: items, folders: children)
            }
            return node(id: nil, title: "")
        }
    }

    public func addFolder(title: String, parent: Int64?) async throws -> Int64 {
        try await writer.write { db in
            try Self.insertFolder(title: title, parent: parent, in: db)
        }
    }

    private static func insertFolder(title: String, parent: Int64?, in db: Database) throws -> Int64 {
        try db.execute(sql: "INSERT INTO bookmarkFolders (title, parentId) VALUES (?, ?)", arguments: [title, parent])
        return db.lastInsertedRowID
    }

    public func renameFolder(_ id: Int64, to title: String) async throws {
        try await writer.write { db in
            try db.execute(sql: "UPDATE bookmarkFolders SET title = ? WHERE id = ?", arguments: [title, id])
        }
    }

    /// Removes the folder, its subfolders and their bookmarks.
    public func deleteFolder(_ id: Int64) async throws {
        try await writer.write { db in
            try db.execute(sql: "DELETE FROM bookmarkFolders WHERE id = ?", arguments: [id])
        }
    }

    public func moveBookmark(url: URL, to folder: Int64) async throws {
        try await writer.write { db in
            try db.execute(sql: "UPDATE bookmarks SET folderId = ? WHERE url = ?", arguments: [folder, url.absoluteString])
        }
    }

    /// All or nothing, so a failed import leaves no half-copied folders. Existing addresses are kept as they are.
    public func importBookmarks(_ tree: BookmarkTree) async throws -> BookmarkImportResult {
        try await writer.write { db in
            var added = 0
            var skipped = 0

            func insert(_ tree: BookmarkTree, into folder: Int64?) throws {
                for item in tree.items {
                    try db.execute(
                        sql: "INSERT INTO bookmarks (url, title, folderId) VALUES (?, ?, ?) ON CONFLICT(url) DO NOTHING",
                        arguments: [item.url.absoluteString, item.title, folder]
                    )
                    if db.changesCount > 0 { added += 1 } else { skipped += 1 }
                }
                for child in tree.folders {
                    let existing = try Int64.fetchOne(
                        db,
                        sql: "SELECT id FROM bookmarkFolders WHERE title = ? AND parentId IS ?",
                        arguments: [child.title, folder]
                    )
                    try insert(child, into: existing ?? Self.insertFolder(title: child.title, parent: folder, in: db))
                }
            }
            try insert(tree, into: nil)
            return BookmarkImportResult(added: added, skipped: skipped)
        }
    }

    // MARK: Site permissions

    public func sitePermission(_ kind: SitePermissionKind, site: String) async throws -> Bool? {
        try await writer.read { db in
            try Bool.fetchOne(
                db,
                sql: "SELECT isAllowed FROM sitePermissions WHERE site = ? AND kind = ?",
                arguments: [site, kind.rawValue]
            )
        }
    }

    public func setSitePermission(_ kind: SitePermissionKind, site: String, allowed: Bool) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "INSERT OR REPLACE INTO sitePermissions (site, kind, isAllowed) VALUES (?, ?, ?)",
                arguments: [site, kind.rawValue, allowed]
            )
        }
    }

    public func removeSitePermission(_ kind: SitePermissionKind, site: String) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "DELETE FROM sitePermissions WHERE site = ? AND kind = ?",
                arguments: [site, kind.rawValue]
            )
        }
    }

    public func allSitePermissions() async throws -> [SitePermission] {
        try await writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM sitePermissions ORDER BY site, kind").compactMap { row in
                SitePermissionKind(rawValue: row["kind"]).map {
                    SitePermission(site: row["site"], kind: $0, isAllowed: row["isAllowed"])
                }
            }
        }
    }

    // MARK: Favicons

    public func favicon(host: String) async throws -> Data? {
        try await writer.read { db in
            try Data.fetchOne(db, sql: "SELECT data FROM favicons WHERE host = ?", arguments: [host])
        }
    }

    public func saveFavicon(host: String, data: Data) async throws {
        try await writer.write { db in
            try db.execute(sql: "INSERT OR REPLACE INTO favicons (host, data) VALUES (?, ?)", arguments: [host, data])
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
                    INSERT INTO sessionTabs (windowIndex, position, url, title, isSelected, interactionState, isPinned)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        windowIndex, position, tab.url.absoluteString, tab.title,
                        tab.isSelected, tab.interactionState, tab.isPinned,
                    ]
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
                    interactionState: row["interactionState"],
                    isPinned: row["isPinned"]
                )
                windows[row["windowIndex"], default: []].append(tab)
            }
            return windows.keys.sorted().compactMap { windows[$0].map(SessionWindow.init) }
        }
    }
}
