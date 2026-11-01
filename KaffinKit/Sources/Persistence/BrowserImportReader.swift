import BrowserCore
import Foundation
import GRDB

public struct EncryptedLogin: Sendable, Equatable {
    public let url: String
    public let username: String
    public let password: Data
}

/// Reads other browsers' databases from a private copy, so the originals are never opened or locked.
public enum BrowserImportReader {
    private static func withCopy<T>(of source: URL, _ body: (DatabaseQueue) throws -> T) throws -> T {
        let folder = FileManager.default.temporaryDirectory.appending(path: "kaffin-import-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The copy of a login database holds encrypted passwords.
        defer { try? FileManager.default.removeItem(at: folder) }
        let copy = folder.appending(path: "copy.sqlite")
        try FileManager.default.copyItem(at: source, to: copy)
        for suffix in ["-wal", "-shm"] {
            let sidecar = URL(filePath: source.path(percentEncoded: false) + suffix)
            try? FileManager.default.copyItem(at: sidecar, to: URL(filePath: copy.path(percentEncoded: false) + suffix))
        }
        let queue = try DatabaseQueue(path: copy.path(percentEncoded: false))
        defer { try? queue.close() }
        return try body(queue)
    }

    public static func chromiumHistory(at file: URL) throws -> [HistoryEntry] {
        try withCopy(of: file) { queue in
            try queue.read { db in
                try Row.fetchAll(db, sql: """
                SELECT url, title, visit_count, last_visit_time FROM urls
                WHERE hidden = 0 ORDER BY last_visit_time DESC LIMIT ?
                """, arguments: [BrowserImportFormat.maximumHistoryEntries]).compactMap { row in
                    BrowserImportFormat.historyEntry(
                        url: row["url"],
                        title: row["title"],
                        visitCount: row["visit_count"],
                        lastVisit: BrowserImportFormat.chromiumDate(row["last_visit_time"])
                    )
                }
            }
        }
    }

    public static func chromiumLogins(at file: URL) throws -> [EncryptedLogin] {
        try withCopy(of: file) { queue in
            try queue.read { db in
                try Row.fetchAll(db, sql: """
                SELECT origin_url, username_value, password_value FROM logins WHERE blacklisted_by_user = 0
                """).compactMap { row in
                    guard let password: Data = row["password_value"], !password.isEmpty else { return nil }
                    return EncryptedLogin(url: row["origin_url"], username: row["username_value"], password: password)
                }
            }
        }
    }

    public static func firefoxHistory(at file: URL) throws -> [HistoryEntry] {
        try withCopy(of: file) { queue in
            try queue.read { db in
                try Row.fetchAll(db, sql: """
                SELECT url, title, visit_count, last_visit_date FROM moz_places
                WHERE hidden = 0 AND visit_count > 0 AND last_visit_date IS NOT NULL
                ORDER BY last_visit_date DESC LIMIT ?
                """, arguments: [BrowserImportFormat.maximumHistoryEntries]).compactMap { row in
                    let microseconds: Int64 = row["last_visit_date"]
                    return BrowserImportFormat.historyEntry(
                        url: row["url"],
                        title: row["title"],
                        visitCount: row["visit_count"],
                        lastVisit: Date(timeIntervalSince1970: Double(microseconds) / 1_000_000)
                    )
                }
            }
        }
    }

    /// Mirrors Chrome's shape: the toolbar is the top level, and the other roots stay as folders.
    /// Firefox's tags live under their own root, so they never appear as bookmarks.
    public static func firefoxBookmarks(at file: URL) throws -> BookmarkTree {
        struct Node {
            let id: Int64
            let parent: Int64
            let type: Int
            let title: String?
            let url: String?
            let guid: String
        }
        let nodes = try withCopy(of: file) { queue in
            try queue.read { db in
                try Row.fetchAll(db, sql: """
                SELECT b.id, b.parent, b.type, b.title, b.guid, p.url
                FROM moz_bookmarks b LEFT JOIN moz_places p ON p.id = b.fk ORDER BY b.position
                """).map { Node(id: $0["id"], parent: $0["parent"], type: $0["type"], title: $0["title"], url: $0["url"], guid: $0["guid"]) }
            }
        }
        let children = Dictionary(grouping: nodes, by: \.parent)

        func tree(of id: Int64, title: String, depth: Int) -> BookmarkTree {
            let rows = children[id] ?? []
            let items = rows.compactMap { row -> BookmarkItem? in
                guard row.type == 1, let text = row.url, let url = URL(string: text),
                      url.scheme == "http" || url.scheme == "https" else { return nil }
                return BookmarkItem(url: url, title: row.title ?? text)
            }
            let folders = depth >= BookmarkFile.maximumDepth ? [] : rows
                .filter { $0.type == 2 }
                .map { tree(of: $0.id, title: $0.title ?? "", depth: depth + 1) }
            return BookmarkTree(title: title, items: items, folders: folders)
        }

        func root(_ guid: String) -> BookmarkTree? {
            nodes.first { $0.guid == guid }.map { tree(of: $0.id, title: $0.title ?? "", depth: 0) }
        }

        let toolbar = root("toolbar_____") ?? BookmarkTree()
        let others = ["menu________", "unfiled_____"].compactMap(root).filter { !$0.items.isEmpty || !$0.folders.isEmpty }
        return BookmarkTree(items: toolbar.items, folders: toolbar.folders + others)
    }
}
