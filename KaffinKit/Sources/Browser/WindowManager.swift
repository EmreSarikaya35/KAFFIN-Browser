import AppKit
import BrowserCore
import BrowserUI
import OSLog
import SwiftUI
import Tabs
import UniformTypeIdentifiers

/// Entry point for the app target: owns the browser windows, the menu bar and profile data.
@MainActor
public final class WindowManager: NSObject {
    private static let logger = Logger(subsystem: "com.kaffin.browser", category: "WindowManager")
    private static let maximumBookmarkFileSize = 50_000_000

    private let profiles = ProfileList()
    private let search = SearchSettings()
    private let accent = AccentSettings()
    private var sessions: [UUID: ProfileSession] = [:]
    private var controllers: [BrowserWindowController] = []
    private var isStarted = false
    private var pendingURLs: [URL] = []

    private func session(for id: UUID) -> ProfileSession {
        if let session = sessions[id] { return session }
        let session = ProfileSession(id: id)
        sessions[id] = session
        return session
    }

    /// The profile of the window in use, which menu bar commands act on.
    private var frontSession: ProfileSession {
        let front = controllers.first { $0.window?.isKeyWindow == true } ?? controllers.last
        return session(for: front?.profileID ?? WebViewFactory.defaultProfileID)
    }

    public func start() {
        AppearanceController.shared.applySavedMode()
        NSApp.mainMenu = MainMenuBuilder.build(windowManager: self)
        Task {
            for profile in profiles.profiles {
                let session = session(for: profile.id)
                await session.bookmarks.reload()
                await loadSession(of: session).forEach { openWindow(in: session, restoring: $0) }
            }
            if controllers.isEmpty, pendingURLs.isEmpty { openWindow() }
            isStarted = true
            pendingURLs.forEach(openInFrontWindow)
            pendingURLs = []
        }
    }

    public func openWindow() {
        openWindow(in: frontSession)
    }

    private func openWindow(in session: ProfileSession, restoring window: SessionWindow? = nil, adopting tab: Tabs.Tab? = nil) {
        let controller = BrowserWindowController(
            factory: session.factory,
            bookmarks: session.bookmarks,
            downloads: session.downloads,
            search: search,
            accent: accent,
            credentials: session.credentials,
            favicons: session.favicons,
            suggestions: session.makeSuggestions(includingHistory: true),
            profileID: session.id,
            profileMenu: makeProfileMenu(current: session.id),
            isPrivate: false,
            session: window,
            adopting: tab
        )
        controller.trackChanges(
            onChange: { [weak self, weak session] in
                if let session { self?.scheduleSessionSave(of: session) }
            },
            onPageVisit: { [weak self, weak session] url, title in
                if let session { self?.recordVisit(url: url, title: title, in: session) }
            },
            onPageTitle: { [weak self, weak session] url, title in
                if let session { self?.recordTitle(url: url, title: title, in: session) }
            }
        )
        show(controller, in: session)
        scheduleSessionSave(of: session)
    }

    private func show(_ controller: BrowserWindowController, in session: ProfileSession) {
        controller.onClose = { [weak self] closed in self?.handleClose(of: closed) }
        controller.onNewWindow = { [weak self, weak session] in
            if let session { self?.openWindow(in: session) }
        }
        controller.onNewPrivateWindow = { [weak self, weak session] in
            if let session { self?.openPrivateWindow(in: session) }
        }
        controller.onShowHistory = { [weak self, weak session] in
            if let session { self?.presentHistory(of: session) }
        }
        controller.onShowSettings = { [weak self, weak session] pane in
            if let session { self?.presentSettings(pane, of: session) }
        }
        controller.onMoveTabToNewWindow = { [weak self, weak session] tab, source in
            guard let session else { return }
            if source.isPrivate {
                self?.openPrivateWindow(in: session, factory: source.factory, downloads: source.downloads, adopting: tab)
            } else {
                self?.openWindow(in: session, adopting: tab)
            }
        }
        controllers.append(controller)
        controller.showWindow(nil)
    }

    /// A profile whose last window closes while others stay open must not come back at the next launch.
    /// When every window is closed, the last saved session is kept instead.
    private func handleClose(of closed: BrowserWindowController) {
        controllers.removeAll { $0 === closed }
        guard !closed.isPrivate, let session = sessions[closed.profileID] else { return }
        let isLastOfProfile = !controllers.contains { !$0.isPrivate && $0.profileID == session.id }
        if isLastOfProfile, controllers.contains(where: { !$0.isPrivate }) {
            session.saveTask?.cancel()
            Task { try? await session.database?.saveSession([]) }
        } else {
            scheduleSessionSave(of: session)
        }
    }

    /// A moved private tab brings its session's factory, so its site data stays with it.
    private func openPrivateWindow(
        in session: ProfileSession,
        factory: WebViewFactory = .privateSession(),
        downloads: DownloadManager? = nil,
        adopting tab: Tabs.Tab? = nil
    ) {
        show(BrowserWindowController(
            factory: factory,
            bookmarks: session.bookmarks,
            downloads: downloads ?? DownloadManager(factory: factory),
            search: search,
            accent: accent,
            credentials: nil,
            favicons: nil,
            suggestions: session.makeSuggestions(includingHistory: false),
            profileID: session.id,
            profileMenu: nil,
            isPrivate: true,
            session: nil,
            adopting: tab
        ), in: session)
    }

    private func makeProfileMenu(current id: UUID) -> ProfileMenu {
        ProfileMenu(
            list: profiles,
            current: id,
            onOpen: { [weak self] in self?.openProfile($0) },
            onAdd: { [weak self] in self?.addProfile() },
            onRename: { [weak self] in self?.renameProfile(id) },
            onDelete: { [weak self] in self?.deleteProfile(id) }
        )
    }

    private func openProfile(_ id: UUID) {
        if let window = controllers.last(where: { !$0.isPrivate && $0.profileID == id })?.window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let session = session(for: id)
        Task {
            await session.bookmarks.reload()
            openWindow(in: session)
        }
    }

    private func addProfile() {
        let title = L10n.string("profile.add")
        guard let name = Prompts.name(title, current: "", placeholder: L10n.string("profile.name")),
              let profile = profiles.add(name: name) else { return }
        openProfile(profile.id)
    }

    private func renameProfile(_ id: UUID) {
        let current = profiles.profiles.first { $0.id == id }?.name ?? ""
        let title = L10n.string("profile.rename")
        if let name = Prompts.name(title, current: current, placeholder: L10n.string("profile.name")) {
            profiles.rename(id, to: name)
        }
    }

    private func deleteProfile(_ id: UUID) {
        let name = profiles.profiles.first { $0.id == id }?.name ?? ""
        let question = String(format: L10n.string("profile.deleteConfirm"), name)
        guard id != WebViewFactory.defaultProfileID,
              Prompts.confirmDelete(question, detail: L10n.string("profile.deleteDetail")) else { return }

        // Forgotten first, so closing its windows cannot write a new session into data being deleted.
        let session = sessions.removeValue(forKey: id)
        session?.saveTask?.cancel()
        controllers.filter { $0.profileID == id }.forEach { $0.close() }
        session?.historyWindow?.close()
        session?.settingsWindow?.close()
        _ = profiles.remove(id)
        if controllers.isEmpty { openWindow() }

        Task {
            do {
                try await ProfileSession.removeData(for: id)
            } catch {
                Self.logger.error("Could not remove profile data: \(String(describing: error), privacy: .public)")
                showAlert(L10n.string("profile.deleteFailed"))
            }
        }
    }

    private func presentSettings(_ pane: SettingsPane, of session: ProfileSession) {
        session.settingsNavigation.pane = pane
        if let window = session.settingsWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let view = SettingsView(
            navigation: session.settingsNavigation,
            search: search,
            accent: accent,
            passwords: session.passwords
        ) { [weak self] in
            self?.setAsDefaultBrowser(nil)
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = windowTitle(L10n.string("settings.title"), of: session)
        window.isReleasedWhenClosed = false
        session.settingsWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    private func presentHistory(of session: ProfileSession) {
        Task { await session.history.reload() }
        if let window = session.historyWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let view = HistoryView(model: session.history) { [weak self, weak session] url in
            if let session { self?.open(url, in: session) }
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = windowTitle(L10n.string("history.title"), of: session)
        window.isReleasedWhenClosed = false
        window.setContentSize(NSSize(width: 640, height: 520))
        session.historyWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    /// Names the profile, so history and passwords are never mistaken for another profile's.
    private func windowTitle(_ title: String, of session: ProfileSession) -> String {
        let name = profiles.profiles.first { $0.id == session.id }?.name ?? ""
        return profiles.profiles.count > 1 ? "\(title) – \(name)" : title
    }

    /// A link that launches the app arrives before the session loads, so it waits to join the restored windows.
    public func openURLs(_ urls: [URL]) {
        if isStarted {
            urls.forEach(openInFrontWindow)
        } else {
            pendingURLs += urls
        }
    }

    private func openInFrontWindow(_ url: URL) {
        open(url, in: frontSession)
    }

    private func open(_ url: URL, in session: ProfileSession) {
        guard let controller = controllers.last(where: { !$0.isPrivate && $0.profileID == session.id }) else {
            openWindow(in: session, restoring: SessionWindow(tabs: [
                SessionTab(url: url, title: nil, isSelected: true, interactionState: nil),
            ]))
            return
        }
        controller.open(url)
        controller.window?.makeKeyAndOrderFront(nil)
    }

    private func recordVisit(url: URL, title: String?, in session: ProfileSession) {
        guard let database = session.database else { return }
        Task {
            do {
                try await database.recordVisit(url: url, title: title, at: .now)
            } catch {
                Self.logger.error("Could not record visit: \(error.localizedDescription)")
            }
        }
    }

    private func recordTitle(url: URL, title: String, in session: ProfileSession) {
        guard let database = session.database else { return }
        Task {
            do {
                try await database.updateHistoryTitle(url: url, title: title)
            } catch {
                Self.logger.error("Could not update history title: \(error.localizedDescription)")
            }
        }
    }

    private func loadSession(of session: ProfileSession) async -> [SessionWindow] {
        do {
            return try await session.database?.loadSession() ?? []
        } catch {
            Self.logger.error("Could not load session: \(error.localizedDescription)")
            return []
        }
    }

    /// Private windows never reach the session. Closing every window keeps the last saved one.
    private func sessionSnapshot(of session: ProfileSession) -> [SessionWindow] {
        controllers
            .filter { !$0.isPrivate && $0.profileID == session.id }
            .map(\.snapshot)
            .filter { !$0.tabs.isEmpty }
    }

    private func scheduleSessionSave(of session: ProfileSession) {
        session.saveTask?.cancel()
        session.saveTask = Task { [weak self, weak session] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self, let session else { return }
            let windows = self.sessionSnapshot(of: session)
            guard !windows.isEmpty else { return }
            do {
                try await session.database?.saveSession(windows)
            } catch {
                Self.logger.error("Could not save session: \(error.localizedDescription)")
            }
        }
    }

    public func saveSessionNow() {
        for session in sessions.values {
            session.saveTask?.cancel()
            let windows = sessionSnapshot(of: session)
            guard !windows.isEmpty else { continue }
            do {
                try session.database?.saveSessionBlocking(windows)
            } catch {
                Self.logger.error("Could not save session: \(error.localizedDescription)")
            }
        }
    }

    @objc func newWindow(_ sender: Any?) {
        openWindow()
    }

    @objc func newPrivateWindow(_ sender: Any?) {
        openPrivateWindow(in: frontSession)
    }

    @objc func showHistory(_ sender: Any?) {
        presentHistory(of: frontSession)
    }

    @objc func showSettings(_ sender: Any?) {
        presentSettings(.general, of: frontSession)
    }

    @objc func importBookmarks(_ sender: Any?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.html]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let session = frontSession
        Task { await importBookmarks(from: url, into: session) }
    }

    private func importBookmarks(from url: URL, into session: ProfileSession) async {
        guard let database = session.database else {
            showAlert(L10n.string("bookmark.importFailed"))
            return
        }
        do {
            guard try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 <= Self.maximumBookmarkFileSize else {
                showAlert(L10n.string("bookmark.importTooLarge"))
                return
            }
            let data = try Data(contentsOf: url)
            let tree = BookmarkFile.parse(String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self))
            guard !tree.items.isEmpty || !tree.folders.isEmpty else {
                showAlert(L10n.string("bookmark.importEmpty"))
                return
            }
            let result = try await database.importBookmarks(tree)
            await session.bookmarks.reload()
            session.bookmarks.isBarVisible = true
            showAlert(String(format: L10n.string("bookmark.importDone"), result.added, result.skipped))
        } catch {
            Self.logger.error("Could not import bookmarks: \(error.localizedDescription)")
            showAlert(L10n.string("bookmark.importFailed"))
        }
    }

    @objc func exportBookmarks(_ sender: Any?) {
        let tree = frontSession.bookmarks.tree
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "bookmarks.html"
        panel.allowedContentTypes = [.html]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try BookmarkFile.export(tree).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            Self.logger.error("Could not export bookmarks: \(error.localizedDescription)")
            showAlert(L10n.string("bookmark.exportFailed"))
        }
    }

    private func showAlert(_ message: String) {
        let alert = NSAlert()
        alert.messageText = message
        alert.runModal()
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
}
