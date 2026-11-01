import Foundation
import Observation

/// Browsers whose data folder KAFFIN can read directly. Each path must also be listed in the entitlements.
public enum ImportBrowser: String, CaseIterable, Sendable, Identifiable {
    case chrome, edge, brave, opera, vivaldi, arc, firefox

    public var id: Self { self }

    public var name: String {
        switch self {
        case .chrome: "Google Chrome"
        case .edge: "Microsoft Edge"
        case .brave: "Brave"
        case .opera: "Opera"
        case .vivaldi: "Vivaldi"
        case .arc: "Arc"
        case .firefox: "Firefox"
        }
    }

    /// Relative to `~/Library/Application Support`.
    public var dataPath: String {
        switch self {
        case .chrome: "Google/Chrome"
        case .edge: "Microsoft Edge"
        case .brave: "BraveSoftware/Brave-Browser"
        case .opera: "com.operasoftware.Opera"
        case .vivaldi: "Vivaldi"
        case .arc: "Arc/User Data"
        case .firefox: "Firefox/Profiles"
        }
    }

    /// The Keychain item that unlocks saved passwords. Firefox keeps no such item.
    public var safeStorage: (service: String, account: String)? {
        switch self {
        case .chrome: ("Chrome Safe Storage", "Chrome")
        case .edge: ("Microsoft Edge Safe Storage", "Microsoft Edge")
        case .brave: ("Brave Safe Storage", "Brave")
        case .opera: ("Opera Safe Storage", "Opera")
        case .vivaldi: ("Vivaldi Safe Storage", "Vivaldi")
        case .arc: ("Arc Safe Storage", "Arc")
        case .firefox: nil
        }
    }
}

public struct ImportedLogin: Sendable, Equatable {
    public let url: String
    public let username: String
    public let password: String

    public init(url: String, username: String, password: String) {
        self.url = url
        self.username = username
        self.password = password
    }
}

public struct ImportedData: Sendable {
    public var bookmarks: [BookmarkTree] = []
    public var history: [HistoryEntry] = []
    public var logins: [ImportedLogin] = []
    public var couldNotReadPasswords = false

    public init() {}
}

/// macOS can protect a browser's folder from every other app until the user allows Full Disk Access.
public struct ImportAccessDenied: Error {
    public init() {}
}

public struct ImportSummary: Sendable, Equatable {
    public var bookmarks = 0
    public var history = 0
    public var passwords = 0
    public var couldNotReadPasswords = false

    public init() {}
}

/// Parsers for what other browsers leave on disk. All of it is outside data.
public enum BrowserImportFormat {
    public static let maximumHistoryEntries = 100_000

    public static func isAccessDenied(_ error: Error) -> Bool {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain, error.code == NSFileReadNoPermissionError { return true }
        if error.domain == NSPOSIXErrorDomain, error.code == EPERM || error.code == EACCES { return true }
        return (error.userInfo[NSUnderlyingErrorKey] as? Error).map(isAccessDenied) ?? false
    }

    private static func webURL(_ text: String?) -> URL? {
        guard let text, let url = URL(string: text), url.scheme == "http" || url.scheme == "https" else { return nil }
        return url
    }

    public static func historyEntry(url: String, title: String?, visitCount: Int, lastVisit: Date) -> HistoryEntry? {
        webURL(url).map { HistoryEntry(url: $0, title: title.flatMap { $0.isEmpty ? nil : $0 }, visitCount: max(visitCount, 1), lastVisit: lastVisit) }
    }

    /// Chromium counts microseconds from 1601, not 1970.
    public static func chromiumDate(_ microseconds: Int64) -> Date {
        Date(timeIntervalSince1970: Double(microseconds) / 1_000_000 - 11_644_473_600)
    }

    /// The bookmarks bar becomes the top level, and Chrome's other roots stay as folders.
    public static func chromiumBookmarks(_ data: Data) -> BookmarkTree {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let roots = json["roots"] as? [String: Any] else { return BookmarkTree() }
        let bar = (roots["bookmark_bar"] as? [String: Any]).map { chromiumNode($0, depth: 0) } ?? BookmarkTree()
        let others = ["other", "synced"].compactMap { roots[$0] as? [String: Any] }
            .map { chromiumNode($0, depth: 0) }
            .filter { !$0.items.isEmpty || !$0.folders.isEmpty }
        return BookmarkTree(items: bar.items, folders: bar.folders + others)
    }

    private static func chromiumNode(_ node: [String: Any], depth: Int) -> BookmarkTree {
        let children = node["children"] as? [[String: Any]] ?? []
        let items = children.compactMap { child -> BookmarkItem? in
            guard child["type"] as? String == "url", let url = webURL(child["url"] as? String) else { return nil }
            return BookmarkItem(url: url, title: child["name"] as? String ?? url.absoluteString)
        }
        let folders = depth >= BookmarkFile.maximumDepth ? [] : children
            .filter { $0["type"] as? String == "folder" }
            .map { chromiumNode($0, depth: depth + 1) }
        return BookmarkTree(title: node["name"] as? String ?? "", items: items, folders: folders)
    }

    /// Safari's "Export Browsing Data" history file.
    public static func safariHistory(_ data: Data) -> [HistoryEntry] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["history"] as? [[String: Any]] else { return [] }
        return rows.prefix(maximumHistoryEntries).compactMap { row in
            guard let url = row["url"] as? String, let time = row["time_usec"] as? Double else { return nil }
            return historyEntry(
                url: url,
                title: row["title"] as? String,
                visitCount: row["visit_count"] as? Int ?? 1,
                lastVisit: Date(timeIntervalSince1970: time / 1_000_000)
            )
        }
    }

    /// Chrome, Firefox and Safari name their columns differently but all use `url`, `username` and `password`.
    public static func passwordsCSV(_ text: String) -> [ImportedLogin] {
        let rows = csvRows(text)
        guard let header = rows.first?.map({ $0.lowercased().trimmingCharacters(in: .whitespaces) }),
              let url = header.firstIndex(of: "url"),
              let username = header.firstIndex(of: "username"),
              let password = header.firstIndex(of: "password") else { return [] }
        return rows.dropFirst().compactMap { row in
            guard row.count > max(url, username, password), !row[password].isEmpty else { return nil }
            return ImportedLogin(url: row[url], username: row[username], password: row[password])
        }
    }

    /// RFC 4180: quotes may contain commas, line breaks and doubled quotes.
    private static func csvRows(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var isQuoted = false
        var characters = Array(text.drop { $0 == "\u{FEFF}" })[...]
        while let character = characters.popFirst() {
            if isQuoted {
                if character != "\"" {
                    field.append(character)
                } else if characters.first == "\"" {
                    field.append(characters.removeFirst())
                } else {
                    isQuoted = false
                }
            } else if character == "\"" {
                isQuoted = true
            } else if character == "," {
                row.append(field)
                field = ""
            } else if character.isNewline {
                row.append(field)
                field = ""
                if row != [""] { rows.append(row) }
                row = []
            } else {
                field.append(character)
            }
        }
        row.append(field)
        if row != [""] { rows.append(row) }
        return rows
    }

    /// Passwords already in KAFFIN win, so importing never replaces a newer one.
    public static func save(_ logins: [ImportedLogin], to store: any CredentialStoring) async throws -> Int {
        var known = Set(try await store.logins(for: nil))
        var added = 0
        for login in logins {
            guard let origin = LoginOrigin.make(from: URL(string: login.url)) else { continue }
            let saved = SavedLogin(origin: origin, username: login.username)
            guard known.insert(saved).inserted else { continue }
            try await store.save(saved, password: login.password)
            added += 1
        }
        return added
    }
}

@MainActor
@Observable
public final class BrowserImportModel {
    public private(set) var browsers: [ImportBrowser] = []
    public private(set) var isImporting = false
    public private(set) var summary: ImportSummary?
    public private(set) var didFail = false
    public private(set) var needsDiskAccess = false
    @ObservationIgnored private let detect: () -> [ImportBrowser]
    @ObservationIgnored private let importBrowser: (ImportBrowser) async throws -> ImportSummary
    @ObservationIgnored private let importFile: (URL) async throws -> ImportSummary

    public init(
        detect: @escaping () -> [ImportBrowser],
        importBrowser: @escaping (ImportBrowser) async throws -> ImportSummary,
        importFile: @escaping (URL) async throws -> ImportSummary
    ) {
        self.detect = detect
        self.importBrowser = importBrowser
        self.importFile = importFile
    }

    public func reload() {
        browsers = detect()
    }

    public func start(_ browser: ImportBrowser) async {
        await run { try await self.importBrowser(browser) }
    }

    public func start(file: URL) async {
        await run { try await self.importFile(file) }
    }

    private func run(_ work: () async throws -> ImportSummary) async {
        isImporting = true
        didFail = false
        needsDiskAccess = false
        summary = nil
        do {
            summary = try await work()
        } catch is ImportAccessDenied {
            needsDiskAccess = true
        } catch {
            didFail = true
        }
        isImporting = false
    }
}
