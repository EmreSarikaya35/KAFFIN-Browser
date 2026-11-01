import BrowserCore
import Credentials
import Foundation
import OSLog
import Persistence

/// Copies another browser's data into one profile. It never writes to that browser's files.
@MainActor
final class BrowserImporter {
    private static let logger = Logger(subsystem: "com.kaffin.browser", category: "BrowserImporter")
    private nonisolated static let maximumFileSize = 200_000_000

    private let database: ProfileDatabase?
    private let credentials: KeychainCredentialStore
    private let onFinish: (ImportSummary) async -> Void

    init(database: ProfileDatabase?, credentials: KeychainCredentialStore, onFinish: @escaping (ImportSummary) async -> Void) {
        self.database = database
        self.credentials = credentials
        self.onFinish = onFinish
    }

    /// `NSHomeDirectory()` is the sandbox container, but the other browsers live in the real home folder.
    private nonisolated static var supportFolder: URL {
        let home = getpwuid(getuid()).flatMap { String(validatingCString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        return URL(filePath: home).appending(path: "Library/Application Support")
    }

    private nonisolated static func root(of browser: ImportBrowser) -> URL {
        supportFolder.appending(path: browser.dataPath)
    }

    /// Asks about known file names, because macOS may refuse to list the folder itself.
    nonisolated static func installedBrowsers() -> [ImportBrowser] {
        ImportBrowser.allCases.filter { browser in
            let exists = FileManager.default.fileExists(atPath: root(of: browser).path(percentEncoded: false))
            return browser == .firefox ? exists : exists && !chromiumProfiles(of: browser).isEmpty
        }
    }

    /// Opera keeps its one profile directly in the data folder.
    private nonisolated static func chromiumProfiles(of browser: ImportBrowser) -> [URL] {
        let root = root(of: browser)
        let names = ["", "Default"] + (1...20).map { "Profile \($0)" }
        let profiles = names.map { $0.isEmpty ? root : root.appending(path: $0) }
            .filter { FileManager.default.fileExists(atPath: $0.appending(path: "History").path(percentEncoded: false)) }
        return profiles.first == root ? [root] : profiles
    }

    private nonisolated static func profiles(of browser: ImportBrowser) throws -> [URL] {
        guard browser == .firefox else { return chromiumProfiles(of: browser) }
        return try FileManager.default.contentsOfDirectory(at: root(of: browser), includingPropertiesForKeys: nil)
            .filter { FileManager.default.fileExists(atPath: $0.appending(path: "places.sqlite").path(percentEncoded: false)) }
    }

    func run(_ browser: ImportBrowser) async throws -> ImportSummary {
        do {
            let data = try await Task.detached { try Self.read(browser) }.value
            return try await store(data)
        } catch where BrowserImportFormat.isAccessDenied(error) {
            throw ImportAccessDenied()
        }
    }

    func run(file: URL) async throws -> ImportSummary {
        let data = try await Task.detached { try Self.read(file: file) }.value
        return try await store(data)
    }

    private nonisolated static func read(_ browser: ImportBrowser) throws -> ImportedData {
        var data = ImportedData()
        var encrypted: [EncryptedLogin] = []
        for profile in try profiles(of: browser) {
            if browser == .firefox {
                data.bookmarks.append(try BrowserImportReader.firefoxBookmarks(at: profile.appending(path: "places.sqlite")))
                data.history += try BrowserImportReader.firefoxHistory(at: profile.appending(path: "places.sqlite"))
                continue
            }
            if let bookmarks = try? Data(contentsOf: profile.appending(path: "Bookmarks")) {
                data.bookmarks.append(BrowserImportFormat.chromiumBookmarks(bookmarks))
            }
            data.history += try BrowserImportReader.chromiumHistory(at: profile.appending(path: "History"))
            if let logins = try? BrowserImportReader.chromiumLogins(at: profile.appending(path: "Login Data")) {
                encrypted += logins
            }
        }
        guard let storage = browser.safeStorage, !encrypted.isEmpty else { return data }
        // Refusing the Keychain question must not lose the bookmarks and history already read.
        guard let key = try? ChromiumPasswords.key(service: storage.service, account: storage.account) else {
            data.couldNotReadPasswords = true
            return data
        }
        data.logins = encrypted.compactMap { login in
            ChromiumPasswords.decrypt(login.password, key: key).map {
                ImportedLogin(url: login.url, username: login.username, password: $0)
            }
        }
        data.couldNotReadPasswords = data.logins.count < encrypted.count
        return data
    }

    private nonisolated static func read(file: URL) throws -> ImportedData {
        guard try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 <= maximumFileSize else {
            throw CocoaError(.fileReadTooLarge)
        }
        var data = ImportedData()
        switch file.pathExtension.lowercased() {
        case "csv":
            data.logins = BrowserImportFormat.passwordsCSV(String(decoding: try Data(contentsOf: file), as: UTF8.self))
        case "html", "htm":
            data.bookmarks = [BookmarkFile.parse(String(decoding: try Data(contentsOf: file), as: UTF8.self))]
        case "zip":
            data = try readSafariExport(file)
        default:
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        return data
    }

    /// Safari keeps its data behind a macOS privacy wall, so its own export file is the only way in.
    private nonisolated static func readSafariExport(_ file: URL) throws -> ImportedData {
        let folder = FileManager.default.temporaryDirectory.appending(path: "kaffin-import-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The unpacked export holds passwords in plain text.
        defer { try? FileManager.default.removeItem(at: folder) }
        let archive = folder.appending(path: "export.zip")
        try FileManager.default.copyItem(at: file, to: archive)
        let unpacked = folder.appending(path: "export")
        let unzip = Process()
        unzip.executableURL = URL(filePath: "/usr/bin/ditto")
        unzip.arguments = ["-x", "-k", archive.path(percentEncoded: false), unpacked.path(percentEncoded: false)]
        try unzip.run()
        unzip.waitUntilExit()
        guard unzip.terminationStatus == 0 else { throw CocoaError(.fileReadCorruptFile) }

        var data = ImportedData()
        let files = FileManager.default.enumerator(at: unpacked, includingPropertiesForKeys: nil)
        while let item = files?.nextObject() as? URL {
            switch item.lastPathComponent {
            case "Bookmarks.html":
                data.bookmarks.append(BookmarkFile.parse(String(decoding: try Data(contentsOf: item), as: UTF8.self)))
            case "History.json":
                data.history += BrowserImportFormat.safariHistory(try Data(contentsOf: item))
            case "Passwords.csv":
                data.logins += BrowserImportFormat.passwordsCSV(String(decoding: try Data(contentsOf: item), as: UTF8.self))
            default:
                break
            }
        }
        return data
    }

    private func store(_ data: ImportedData) async throws -> ImportSummary {
        guard let database else { throw CocoaError(.fileWriteUnknown) }
        var summary = ImportSummary()
        summary.couldNotReadPasswords = data.couldNotReadPasswords
        for tree in data.bookmarks {
            summary.bookmarks += try await database.importBookmarks(tree).added
        }
        summary.history = try await database.importHistory(data.history)
        do {
            summary.passwords = try await BrowserImportFormat.save(data.logins, to: credentials)
        } catch {
            Self.logger.error("Could not save imported passwords: \(error.localizedDescription)")
            summary.couldNotReadPasswords = true
        }
        await onFinish(summary)
        return summary
    }
}
