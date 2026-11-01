import AppKit
import BrowserCore
import BrowserUI
import Credentials
import Extensions
import Foundation
import OSLog
import Persistence
import WebKit

/// Everything that belongs to one profile, so nothing here can leak into another profile's windows.
@MainActor
final class ProfileSession {
    private static let logger = Logger(subsystem: "com.kaffin.browser", category: "ProfileSession")

    let id: UUID
    let factory: WebViewFactory
    let database: ProfileDatabase?
    let bookmarks: BookmarksModel
    let history: HistoryModel
    let credentials: KeychainCredentialStore
    let passwords: PasswordsModel
    let favicons: FaviconLoader
    let sitePermissions: SitePermissionsModel
    let extensions: ExtensionHost
    private var isPrepared = false
    let downloads: DownloadManager
    let settingsNavigation = SettingsNavigation()
    let browserImport: BrowserImportModel
    var saveTask: Task<Void, Never>?

    init(id: UUID) {
        self.id = id
        let database = Self.openDatabase(for: id)
        self.database = database
        let factory = WebViewFactory(profileID: id)
        self.factory = factory
        downloads = DownloadManager(factory: factory)
        let folder = (try? Self.directory(for: id))?.appending(path: "Extensions") ?? URL.temporaryDirectory
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        extensions = ExtensionHost(profileID: id, directory: folder, factory: factory, approve: Self.askToApprove)
        bookmarks = BookmarksModel(store: database)
        history = HistoryModel(store: database)
        credentials = KeychainCredentialStore(profileID: id)
        passwords = PasswordsModel(store: credentials)
        favicons = FaviconLoader(store: database)
        sitePermissions = SitePermissionsModel(store: database)
        let importer = BrowserImporter(database: database, credentials: credentials) { [bookmarks, history, passwords] summary in
            await bookmarks.reload()
            if summary.bookmarks > 0 { bookmarks.isBarVisible = true }
            await history.reload()
            await passwords.reload()
        }
        browserImport = BrowserImportModel(
            detect: BrowserImporter.installedBrowsers,
            importBrowser: { try await importer.run($0) },
            importFile: { try await importer.run(file: $0) }
        )
    }

    /// Loads saved state once, before the profile's first window opens.
    func prepare() async {
        guard !isPrepared else { return }
        isPrepared = true
        await bookmarks.reload()
        await extensions.loadInstalled()
        if database == nil {
            let alert = NSAlert()
            alert.messageText = L10n.string("dialog.databaseFailed")
            alert.informativeText = L10n.string("dialog.databaseFailedDetail")
            alert.alertStyle = .warning
            alert.runModal()
        }
    }

    private static func askToApprove(_ approval: ExtensionHost.Approval) -> Bool {
        let detail = (approval.permissions + approval.sites).joined(separator: "\n")
        return Prompts.confirm(
            String(format: L10n.string("extensions.approveTitle"), approval.name),
            detail: detail.isEmpty ? L10n.string("extensions.noPermissions") : detail,
            action: L10n.string("extensions.approve")
        )
    }

    func clearData(_ request: ClearDataRequest) async {
        if request.history {
            try? await database?.deleteHistory(since: request.since)
            await history.reload()
        }
        let cache: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache, WKWebsiteDataTypeFetchCache]
        var types: Set<String> = request.cache ? cache : []
        if request.siteData { types.formUnion(WKWebsiteDataStore.allWebsiteDataTypes().subtracting(cache)) }
        guard !types.isEmpty else { return }
        await factory.dataStore.removeData(ofTypes: types, modifiedSince: request.since)
    }

    func makeSuggestions(includingHistory: Bool) -> SuggestionsModel {
        SuggestionsModel(history: includingHistory ? database : nil) { [bookmarks] in bookmarks.items }
    }

    private static func directory(for id: UUID) throws -> URL {
        try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            .appending(path: "KAFFIN/Profiles/\(id.uuidString)")
    }

    private static func openDatabase(for id: UUID) -> ProfileDatabase? {
        do {
            let directory = try directory(for: id)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return try ProfileDatabase(path: directory.appending(path: "profile.sqlite").path(percentEncoded: false))
        } catch {
            logger.error("Could not open profile database: \(error.localizedDescription)")
            return nil
        }
    }

    /// Run after the session and its windows are gone, or WebKit and SQLite still hold the files.
    /// Every step runs even if an earlier one fails, so one failure leaves as little behind as possible.
    static func removeData(for id: UUID) async throws {
        var failure: Error?
        do { try await KeychainCredentialStore(profileID: id).deleteAll() } catch { failure = error }
        do { try await WebViewFactory.removeProfileData(id) } catch { failure = error }
        do { try FileManager.default.removeItem(at: directory(for: id)) } catch { failure = error }
        if let failure { throw failure }
    }
}
