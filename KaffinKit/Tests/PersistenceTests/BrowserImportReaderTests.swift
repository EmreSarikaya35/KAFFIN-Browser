import BrowserCore
import Foundation
import GRDB
import Testing
@testable import Persistence

/// Fixtures copy the tables Chrome and Firefox really use. Real browser data is never read here.
struct BrowserImportReaderTests {
    private let folder = FileManager.default.temporaryDirectory.appending(path: "kaffin-reader-\(UUID())")

    init() throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    private func fixture(_ sql: String) throws -> URL {
        // A space, because the real path contains "Application Support".
        let file = folder.appending(path: "Source \(UUID()).sqlite")
        let queue = try DatabaseQueue(path: file.path(percentEncoded: false))
        try queue.write { try $0.execute(sql: sql) }
        try queue.close()
        return file
    }

    @Test func readsChromiumHistory() throws {
        let file = try fixture("""
        CREATE TABLE urls (id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER, typed_count INTEGER, last_visit_time INTEGER, hidden INTEGER);
        INSERT INTO urls VALUES (1, 'https://a.example/', 'A', 4, 1, 11644473600000000, 0);
        INSERT INTO urls VALUES (2, 'https://hidden.example/', 'B', 1, 0, 11644473600000000, 1);
        INSERT INTO urls VALUES (3, 'chrome://settings/', 'C', 1, 0, 11644473600000000, 0);
        """)
        let entries = try BrowserImportReader.chromiumHistory(at: file)

        #expect(entries.map(\.url.absoluteString) == ["https://a.example/"])
        #expect(entries[0].visitCount == 4)
        #expect(entries[0].lastVisit == Date(timeIntervalSince1970: 0))
    }

    @Test func readsChromiumLoginsButNotNeverSaveSites() throws {
        let file = try fixture("""
        CREATE TABLE logins (origin_url TEXT, username_value TEXT, password_value BLOB, blacklisted_by_user INTEGER);
        INSERT INTO logins VALUES ('https://a.example/', 'ada', x'763130FF', 0);
        INSERT INTO logins VALUES ('https://never.example/', '', x'', 1);
        """)
        #expect(try BrowserImportReader.chromiumLogins(at: file) == [
            EncryptedLogin(url: "https://a.example/", username: "ada", password: Data([0x76, 0x31, 0x30, 0xFF])),
        ])
    }

    @Test func leavesNoCopyBehindAndTheSourceUnchanged() throws {
        let file = try fixture("CREATE TABLE logins (origin_url TEXT, username_value TEXT, password_value BLOB, blacklisted_by_user INTEGER);")
        let before = try Data(contentsOf: file)
        let leftovers = {
            try FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path(percentEncoded: false))
                .filter { $0.hasPrefix("kaffin-import-") }
        }
        let existing = Set(try leftovers())

        _ = try BrowserImportReader.chromiumLogins(at: file)

        #expect(try Data(contentsOf: file) == before)
        #expect(Set(try leftovers()).subtracting(existing).isEmpty)
    }

    @Test func readsFirefoxHistoryAndBookmarks() throws {
        let file = try fixture("""
        CREATE TABLE moz_places (id INTEGER PRIMARY KEY, url TEXT, title TEXT, visit_count INTEGER, hidden INTEGER, last_visit_date INTEGER);
        CREATE TABLE moz_bookmarks (id INTEGER PRIMARY KEY, type INTEGER, fk INTEGER, parent INTEGER, position INTEGER, title TEXT, guid TEXT);
        INSERT INTO moz_places VALUES (1, 'https://a.example/', 'A', 2, 0, 1000000);
        INSERT INTO moz_places VALUES (2, 'https://never.example/', 'B', 0, 0, NULL);
        INSERT INTO moz_places VALUES (3, 'https://tagged.example/', 'C', 0, 0, NULL);
        INSERT INTO moz_bookmarks VALUES (1, 2, NULL, 0, 0, '', 'root________');
        INSERT INTO moz_bookmarks VALUES (2, 2, NULL, 1, 0, 'toolbar', 'toolbar_____');
        INSERT INTO moz_bookmarks VALUES (3, 2, NULL, 1, 1, 'menu', 'menu________');
        INSERT INTO moz_bookmarks VALUES (4, 2, NULL, 1, 2, 'tags', 'tags________');
        INSERT INTO moz_bookmarks VALUES (5, 2, NULL, 1, 3, 'unfiled', 'unfiled_____');
        INSERT INTO moz_bookmarks VALUES (6, 1, 1, 2, 0, 'Bar Site', 'aaaaaaaaaaaa');
        INSERT INTO moz_bookmarks VALUES (7, 2, NULL, 2, 1, 'Work', 'bbbbbbbbbbbb');
        INSERT INTO moz_bookmarks VALUES (8, 1, 2, 7, 0, 'Inside', 'cccccccccccc');
        INSERT INTO moz_bookmarks VALUES (9, 1, 2, 3, 0, 'Menu Site', 'dddddddddddd');
        INSERT INTO moz_bookmarks VALUES (10, 2, NULL, 4, 0, 'some-tag', 'eeeeeeeeeeee');
        INSERT INTO moz_bookmarks VALUES (11, 1, 3, 10, 0, NULL, 'ffffffffffff');
        """)
        let history = try BrowserImportReader.firefoxHistory(at: file)
        #expect(history.map(\.url.absoluteString) == ["https://a.example/"])
        #expect(history[0].lastVisit == Date(timeIntervalSince1970: 1))

        let tree = try BrowserImportReader.firefoxBookmarks(at: file)
        #expect(tree.items.map(\.title) == ["Bar Site"])
        #expect(tree.folders.map(\.title) == ["Work", "menu"])
        #expect(tree.folders[0].items.map(\.title) == ["Inside"])
    }

    @Test func protectedFileIsReportedAsDeniedAccess() throws {
        let file = try fixture("CREATE TABLE urls (url TEXT);")
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: file.path(percentEncoded: false))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path(percentEncoded: false)) }

        #expect {
            try BrowserImportReader.chromiumHistory(at: file)
        } throws: { BrowserImportFormat.isAccessDenied($0) }
    }

    @Test func damagedFileIsNotReportedAsDeniedAccess() throws {
        let file = folder.appending(path: "Damaged.sqlite")
        try Data("not a database".utf8).write(to: file)

        #expect {
            try BrowserImportReader.chromiumHistory(at: file)
        } throws: { !BrowserImportFormat.isAccessDenied($0) }
    }

    @Test func importingHistoryTwiceChangesNothing() async throws {
        let database = try ProfileDatabase.inMemory()
        let date = Date(timeIntervalSince1970: 1_000_000)
        let entries = [HistoryEntry(url: try #require(URL(string: "https://a.example/")), title: "A", visitCount: 5, lastVisit: date)]

        #expect(try await database.importHistory(entries) == 1)
        #expect(try await database.importHistory(entries) == 0)
        let stored = try await database.recentHistory(limit: 10)
        #expect(stored.map(\.visitCount) == [5])
        #expect(try await database.visitCount() == 1)
    }

    @Test func importKeepsNewerLocalVisit() async throws {
        let database = try ProfileDatabase.inMemory()
        let url = try #require(URL(string: "https://a.example/"))
        let local = Date(timeIntervalSince1970: 2_000_000)
        try await database.recordVisit(url: url, title: "Local", at: local)

        _ = try await database.importHistory([HistoryEntry(url: url, title: "Old", visitCount: 9, lastVisit: Date(timeIntervalSince1970: 1))])

        let stored = try #require(try await database.recentHistory(limit: 1).first)
        #expect(stored.title == "Local")
        #expect(stored.visitCount == 9)
        #expect(stored.lastVisit == local)
    }
}
