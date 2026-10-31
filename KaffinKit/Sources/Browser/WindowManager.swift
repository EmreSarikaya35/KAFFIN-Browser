import AppKit
import BrowserCore
import BrowserUI
import Credentials
import OSLog
import Persistence
import SwiftUI

/// Entry point for the app target: owns the browser windows, the menu bar and profile data.
@MainActor
public final class WindowManager: NSObject {
    private static let logger = Logger(subsystem: "com.kaffin.browser", category: "WindowManager")

    private let factory = WebViewFactory()
    private let database = WindowManager.openDatabase()
    private lazy var bookmarks = BookmarksModel(store: database)
    private lazy var history = HistoryModel(store: database)
    private var controllers: [BrowserWindowController] = []
    private var historyWindow: NSWindow?
    private var saveTask: Task<Void, Never>?
    private let downloads = DownloadManager()
    private let search = SearchSettings()
    private let credentials = KeychainCredentialStore(profileID: WebViewFactory.defaultProfileID)
    private lazy var passwords = PasswordsModel(store: credentials)
    private let settingsNavigation = SettingsNavigation()
    private var settingsWindow: NSWindow?

    public func start() {
        AppearanceController.shared.applySavedMode()
        NSApp.mainMenu = MainMenuBuilder.build(windowManager: self)
        Task {
            await bookmarks.reload()
            let session = await loadSession()
            if session.isEmpty { openWindow() }
            session.forEach { openWindow(session: $0) }
        }
    }

    public func openWindow() {
        openWindow(session: nil)
    }

    private func openWindow(session: SessionWindow?) {
        let controller = BrowserWindowController(
            factory: factory,
            bookmarks: bookmarks,
            downloads: downloads,
            search: search,
            credentials: credentials,
            isPrivate: false,
            session: session
        )
        controller.trackChanges(
            onChange: { [weak self] in self?.scheduleSessionSave() },
            onPageVisit: { [weak self] url, title in self?.recordVisit(url: url, title: title) },
            onPageTitle: { [weak self] url, title in self?.recordTitle(url: url, title: title) }
        )
        show(controller)
    }

    private func show(_ controller: BrowserWindowController) {
        controller.onClose = { [weak self] closed in
            self?.controllers.removeAll { $0 === closed }
            self?.scheduleSessionSave()
        }
        controller.onNewWindow = { [weak self] in self?.openWindow() }
        controller.onNewPrivateWindow = { [weak self] in self?.openPrivateWindow() }
        controller.onShowHistory = { [weak self] in self?.presentHistory() }
        controller.onShowSettings = { [weak self] in self?.presentSettings($0) }
        controllers.append(controller)
        controller.showWindow(nil)
    }

    private func openPrivateWindow() {
        show(BrowserWindowController(
            factory: .privateSession(),
            bookmarks: bookmarks,
            downloads: DownloadManager(),
            search: search,
            credentials: nil,
            isPrivate: true,
            session: nil
        ))
    }

    private func presentSettings(_ pane: SettingsPane) {
        settingsNavigation.pane = pane
        if let settingsWindow {
            settingsWindow.makeKeyAndOrderFront(nil)
            return
        }
        let view = SettingsView(navigation: settingsNavigation, search: search, passwords: passwords) { [weak self] in
            self?.setAsDefaultBrowser(nil)
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = L10n.string("settings.title")
        window.isReleasedWhenClosed = false
        settingsWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    private func presentHistory() {
        Task { await history.reload() }
        if let historyWindow {
            historyWindow.makeKeyAndOrderFront(nil)
            return
        }
        let view = HistoryView(model: history) { [weak self] in self?.openInFrontWindow($0) }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = L10n.string("history.title")
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 640, height: 520))
        historyWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    public func openURLs(_ urls: [URL]) {
        urls.forEach(openInFrontWindow)
    }

    private func openInFrontWindow(_ url: URL) {
        guard let controller = controllers.last(where: { !$0.isPrivate }) else {
            openWindow(session: SessionWindow(tabs: [
                SessionTab(url: url, title: nil, isSelected: true, interactionState: nil),
            ]))
            return
        }
        controller.open(url)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private func recordVisit(url: URL, title: String?) {
        guard let database else { return }
        Task {
            do {
                try await database.recordVisit(url: url, title: title, at: .now)
            } catch {
                Self.logger.error("Could not record visit: \(error.localizedDescription)")
            }
        }
    }

    private func recordTitle(url: URL, title: String) {
        guard let database else { return }
        Task {
            do {
                try await database.updateHistoryTitle(url: url, title: title)
            } catch {
                Self.logger.error("Could not update history title: \(error.localizedDescription)")
            }
        }
    }

    private func loadSession() async -> [SessionWindow] {
        do {
            return try await database?.loadSession() ?? []
        } catch {
            Self.logger.error("Could not load session: \(error.localizedDescription)")
            return []
        }
    }

    /// Private windows never reach the session. Closing every window keeps the last saved one.
    private var sessionSnapshot: [SessionWindow] {
        controllers.filter { !$0.isPrivate }.map(\.snapshot).filter { !$0.tabs.isEmpty }
    }

    private func scheduleSessionSave() {
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, let database = self.database else { return }
            let windows = self.sessionSnapshot
            guard !windows.isEmpty else { return }
            do {
                try await database.saveSession(windows)
            } catch {
                Self.logger.error("Could not save session: \(error.localizedDescription)")
            }
        }
    }

    public func saveSessionNow() {
        saveTask?.cancel()
        let windows = sessionSnapshot
        guard !windows.isEmpty else { return }
        do {
            try database?.saveSessionBlocking(windows)
        } catch {
            Self.logger.error("Could not save session: \(error.localizedDescription)")
        }
    }

    @objc func newWindow(_ sender: Any?) {
        openWindow()
    }

    @objc func newPrivateWindow(_ sender: Any?) {
        openPrivateWindow()
    }

    @objc func showHistory(_ sender: Any?) {
        presentHistory()
    }

    @objc func showSettings(_ sender: Any?) {
        presentSettings(.general)
    }

    @objc func setAsDefaultBrowser(_ sender: Any?) {
        let app = Bundle.main.bundleURL
        Task {
            // macOS asks the user to confirm this change itself.
            for scheme in ["http", "https"] {
                try? await NSWorkspace.shared.setDefaultApplication(at: app, toOpenURLsWithScheme: scheme)
            }
        }
    }

    private static func openDatabase() -> ProfileDatabase? {
        do {
            let directory = try FileManager.default
                .url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appending(path: "KAFFIN/Profiles/\(WebViewFactory.defaultProfileID.uuidString)")
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            return try ProfileDatabase(path: directory.appending(path: "profile.sqlite").path(percentEncoded: false))
        } catch {
            // shortcut: the browser still runs without saved data, but nothing tells the user yet. Show an alert in Phase 7.
            logger.error("Could not open profile database: \(error.localizedDescription)")
            return nil
        }
    }
}
