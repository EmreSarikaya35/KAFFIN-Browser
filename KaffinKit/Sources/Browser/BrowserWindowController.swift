import AppKit
import BrowserCore
import BrowserUI
import SwiftUI
import Tabs
import WebKit

@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    private let tabManager: TabManager
    private let extensions: ExtensionsModel?
    private let bookmarks: BookmarksModel
    let isPrivate: Bool
    let profileID: UUID
    private let profileMenu: ProfileMenu?
    private let webContainer = NSView()
    private var newTabHost: NSHostingView<NewTabView>!
    private var findHost: NSHostingView<FindBarView>!
    private var loginHost: NSHostingView<LoginPromptView>!
    private var suggestionHost: NSHostingView<SuggestionListView>!
    private var storeHost: NSHostingView<StoreInstallView>?
    private var pageDialogs: SheetPageDialogs?
    private let suggestions: SuggestionsModel
    let downloads: DownloadManager
    let factory: WebViewFactory
    private let search: SearchSettings
    private let accent: AccentSettings
    private var chromeHost: NSHostingView<BrowserChromeView>!
    private var focusRequest = 0
    var onClose: ((BrowserWindowController) -> Void)?
    var onNewWindow: (() -> Void)?
    var onNewPrivateWindow: (() -> Void)?
    var onShowHistory: (() -> Void)?
    var onShowSettings: ((SettingsPane) -> Void)?
    var onMoveTabToNewWindow: ((Tabs.Tab, BrowserWindowController) -> Void)?
    private var chromeHeight: NSLayoutConstraint!

    /// Private windows get their own factory, and the caller wires no session or history saving.
    init(
        factory: WebViewFactory,
        bookmarks: BookmarksModel,
        downloads: DownloadManager,
        search: SearchSettings,
        accent: AccentSettings,
        extensions: ExtensionsModel?,
        credentials: (any CredentialStoring)?,
        favicons: FaviconLoader?,
        suggestions: SuggestionsModel,
        profileID: UUID,
        profileMenu: ProfileMenu?,
        isPrivate: Bool,
        session: SessionWindow?,
        adopting tab: Tabs.Tab? = nil
    ) {
        self.factory = factory
        self.extensions = extensions
        self.accent = accent
        self.profileID = profileID
        self.profileMenu = profileMenu
        tabManager = TabManager(
            factory: factory,
            downloads: downloads,
            credentials: credentials,
            favicons: favicons
        )
        self.suggestions = suggestions
        self.search = search
        self.bookmarks = bookmarks
        self.downloads = downloads
        self.isPrivate = isPrivate
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 800),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = NSSize(width: 500, height: 300)
        window.center()
        if isPrivate {
            window.appearance = NSAppearance(named: .darkAqua)
        } else {
            window.setFrameAutosaveName("BrowserWindow")
        }
        super.init(window: window)

        window.delegate = self
        let pageDialogs = SheetPageDialogs(window: window)
        self.pageDialogs = pageDialogs
        tabManager.dialogs = pageDialogs
        installContent(in: window)
        tabManager.onSelectionChange = { [weak self] in self?.show($0) }
        tabManager.onLastTabClosed = { [weak self] in self?.window?.close() }
        tabManager.onMoveToNewWindow = { [weak self] id in
            guard let self, let tab = tabManager.detachTab(id) else { return }
            onMoveTabToNewWindow?(tab, self)
        }
        if let tab {
            tabManager.adopt(tab)
        } else if let session, !session.tabs.isEmpty {
            tabManager.restore(session)
        } else {
            tabManager.newTab()
        }
        updateNewTabPage()
        updateChromeHeight()
        updateLoginPrompt()
        updateSuggestions()
        updateStoreOffer()
    }

    var snapshot: SessionWindow { tabManager.snapshot() }
    var tabs: TabManager { tabManager }

    func trackChanges(
        onChange: @escaping () -> Void,
        onPageVisit: @escaping (URL, String?) -> Void,
        onPageTitle: @escaping (URL, String) -> Void
    ) {
        tabManager.onChange = onChange
        tabManager.onPageVisit = onPageVisit
        tabManager.onPageTitle = onPageTitle
    }

    func sleepEligibleTabs(_ settings: PerformanceSettings, trigger: SleepTrigger) async {
        await tabManager.sleepEligibleTabs(settings, trigger: trigger)
    }

    func open(_ url: URL) {
        tabManager.newTab(url: url)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func installContent(in window: NSWindow) {
        guard let content = window.contentView else { return }
        chromeHost = NSHostingView(rootView: makeChromeView())
        chromeHost.translatesAutoresizingMaskIntoConstraints = false
        // The tab strip fills the titlebar area. Respecting its safe area would push the
        // chrome past its height constraint and over the top of the page.
        chromeHost.safeAreaRegions = []
        chromeHeight = chromeHost.heightAnchor.constraint(equalToConstant: BrowserChromeView.height)
        webContainer.translatesAutoresizingMaskIntoConstraints = false
        newTabHost = NSHostingView(rootView: NewTabView(search: search) { [weak self] in self?.submitAddress($0) })
        newTabHost.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(webContainer)
        findHost = NSHostingView(rootView: makeFindBar())
        findHost.translatesAutoresizingMaskIntoConstraints = false
        findHost.isHidden = true
        content.addSubview(newTabHost)
        content.addSubview(chromeHost)
        content.addSubview(findHost)
        loginHost = NSHostingView(rootView: LoginPromptView(tabManager: tabManager))
        loginHost.translatesAutoresizingMaskIntoConstraints = false
        loginHost.isHidden = true
        content.addSubview(loginHost)
        suggestionHost = NSHostingView(rootView: SuggestionListView(model: suggestions) { [weak self] in
            self?.open($0)
        })
        suggestionHost.translatesAutoresizingMaskIntoConstraints = false
        if let extensions {
            let host = NSHostingView(rootView: StoreInstallView(tabManager: tabManager, extensions: extensions))
            host.translatesAutoresizingMaskIntoConstraints = false
            host.isHidden = true
            content.addSubview(host)
            NSLayoutConstraint.activate([
                // A corner, because the store keeps its search box at the top of the page.
                host.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor, constant: -24),
                host.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor, constant: -28),
            ])
            storeHost = host
        }
        suggestionHost.isHidden = true
        content.addSubview(suggestionHost)
        NSLayoutConstraint.activate([
            chromeHost.topAnchor.constraint(equalTo: content.topAnchor),
            chromeHost.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            chromeHost.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            chromeHeight,
            webContainer.topAnchor.constraint(equalTo: chromeHost.bottomAnchor),
            webContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            webContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            webContainer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            newTabHost.topAnchor.constraint(equalTo: webContainer.topAnchor),
            newTabHost.leadingAnchor.constraint(equalTo: webContainer.leadingAnchor),
            newTabHost.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor),
            newTabHost.bottomAnchor.constraint(equalTo: webContainer.bottomAnchor),
            suggestionHost.topAnchor.constraint(equalTo: chromeHost.bottomAnchor, constant: -6),
            suggestionHost.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 106),
            suggestionHost.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -74),
            loginHost.topAnchor.constraint(equalTo: webContainer.topAnchor, constant: 8),
            loginHost.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor, constant: -16),
            findHost.topAnchor.constraint(equalTo: webContainer.topAnchor, constant: 8),
            findHost.trailingAnchor.constraint(equalTo: webContainer.trailingAnchor, constant: -16),
        ])
    }

    private func makeFindBar() -> FindBarView {
        FindBarView(
            focusRequest: focusRequest,
            onSearch: { [weak self] text, backwards in await self?.find(text, backwards: backwards) ?? false },
            onClose: { [weak self] in self?.closeFind() }
        )
    }

    private func find(_ text: String, backwards: Bool) async -> Bool {
        guard let webView = tabManager.selectedTab?.webView, !text.isEmpty else { return true }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        return (try? await webView.find(text, configuration: configuration).matchFound) ?? false
    }

    private func closeFind() {
        findHost.isHidden = true
        window?.makeFirstResponder(tabManager.selectedTab?.webView)
    }

    private func makeChromeView() -> BrowserChromeView {
        BrowserChromeView(
            tabManager: tabManager,
            bookmarks: bookmarks,
            downloads: downloads,
            search: search,
            accent: accent,
            extensions: extensions,
            suggestions: suggestions,
            profileMenu: profileMenu,
            isPrivate: isPrivate,
            focusRequest: focusRequest
        ) { [weak self] in
            self?.submitAddress($0)
        }
    }

    private func show(_ tab: Tabs.Tab?) {
        webContainer.subviews.forEach { $0.removeFromSuperview() }
        guard let tab else { return }
        tab.webView.frame = webContainer.bounds
        tab.webView.autoresizingMask = [.width, .height]
        webContainer.addSubview(tab.webView)
        if tab.url == nil {
            focusAddressBar()
        } else {
            window?.makeFirstResponder(tab.webView)
        }
    }

    /// Re-registers on every change, so the page tracks tab selection and URL without polling.
    private func updateNewTabPage() {
        let isBlank = withObservationTracking {
            tabManager.selectedTab?.url == nil
        } onChange: { [weak self] in
            Task { @MainActor in self?.updateNewTabPage() }
        }
        newTabHost.isHidden = !isBlank
    }

    private func updateStoreOffer() {
        guard let extensions else { return }
        let offer = withObservationTracking {
            StoreInstallView.offer(tabManager: tabManager, extensions: extensions)
        } onChange: { [weak self] in
            Task { @MainActor in self?.updateStoreOffer() }
        }
        storeHost?.isHidden = offer == nil
    }

    private func updateSuggestions() {
        let hasRows = withObservationTracking {
            !suggestions.items.isEmpty
        } onChange: { [weak self] in
            Task { @MainActor in self?.updateSuggestions() }
        }
        suggestionHost.isHidden = !hasRows
    }

    private func open(_ suggestion: Suggestion) {
        suggestions.clear()
        tabManager.selectedTab?.load(suggestion.url)
        window?.makeFirstResponder(tabManager.selectedTab?.webView)
    }

    private func updateLoginPrompt() {
        let hasPrompt = withObservationTracking {
            tabManager.selectedTab?.loginPrompt != nil
        } onChange: { [weak self] in
            Task { @MainActor in self?.updateLoginPrompt() }
        }
        loginHost.isHidden = !hasPrompt
    }

    private func updateChromeHeight() {
        let isBarVisible = withObservationTracking {
            bookmarks.isBarVisible
        } onChange: { [weak self] in
            Task { @MainActor in self?.updateChromeHeight() }
        }
        chromeHeight.constant = BrowserChromeView.height + (isBarVisible ? BrowserChromeView.bookmarksBarHeight : 0)
    }

    private func submitAddress(_ text: String) {
        if let chosen = suggestions.selected ?? suggestions.defaultSuggestion(for: text) {
            open(chosen)
            return
        }
        suggestions.clear()
        guard let url = AddressResolver.resolve(text, searchEngine: search.engine),
              let tab = tabManager.selectedTab else { return }
        tab.load(url)
        window?.makeFirstResponder(tab.webView)
    }

    private func focusAddressBar() {
        focusRequest += 1
        chromeHost.rootView = makeChromeView()
    }

    @objc func showFind(_ sender: Any?) {
        focusRequest += 1
        findHost.rootView = makeFindBar()
        findHost.isHidden = false
    }

    @objc func printPage(_ sender: Any?) {
        guard let window, let webView = tabManager.selectedTab?.webView else { return }
        let operation = webView.printOperation(with: .shared)
        // WebKit's print view starts empty sized, which prints blank pages.
        operation.view?.frame = webView.bounds
        operation.runModal(for: window, delegate: nil, didRun: nil, contextInfo: nil)
    }

    func windowWillClose(_ notification: Notification) {
        onClose?(self)
    }

    @objc func newTab(_ sender: Any?) {
        tabManager.newTab()
    }

    @objc func newWindow(_ sender: Any?) {
        onNewWindow?()
    }

    @objc func newPrivateWindow(_ sender: Any?) {
        onNewPrivateWindow?()
    }

    @objc func showHistory(_ sender: Any?) {
        onShowHistory?()
    }

    @objc func showSettings(_ sender: Any?) {
        onShowSettings?(.general)
    }

    @objc func showExtensions(_ sender: Any?) {
        onShowSettings?(.extensions)
    }

    @objc func showPasswords(_ sender: Any?) {
        onShowSettings?(.passwords)
    }

    @objc func toggleBookmark(_ sender: Any?) {
        guard let tab = tabManager.selectedTab, let url = tab.url else { return }
        Task { await bookmarks.toggle(url: url, title: tab.title) }
    }

    @objc func toggleBookmarksBar(_ sender: Any?) {
        bookmarks.isBarVisible.toggle()
    }

    @objc func reopenClosedTab(_ sender: Any?) {
        tabManager.reopenClosedTab()
    }

    @objc func selectNumberedTab(_ sender: NSMenuItem) {
        // Cmd+9 always means the last tab, as in Chrome.
        tabManager.selectTab(at: sender.tag == 8 ? tabManager.tabs.count - 1 : sender.tag)
    }

    @objc func zoomIn(_ sender: Any?) {
        changeZoom(by: 0.1)
    }

    @objc func zoomOut(_ sender: Any?) {
        changeZoom(by: -0.1)
    }

    @objc func resetZoom(_ sender: Any?) {
        tabManager.selectedTab?.webView.pageZoom = 1
    }

    private func changeZoom(by delta: CGFloat) {
        guard let webView = tabManager.selectedTab?.webView else { return }
        webView.pageZoom = min(5, max(0.25, webView.pageZoom + delta))
    }

    @objc func closeTab(_ sender: Any?) {
        if let id = tabManager.selectedTabID { tabManager.close(id) }
    }

    @objc func focusAddress(_ sender: Any?) {
        focusAddressBar()
    }

    @objc func reloadPage(_ sender: Any?) {
        tabManager.selectedTab?.webView.reload()
    }

    @objc func goBack(_ sender: Any?) {
        tabManager.selectedTab?.webView.goBack()
    }

    @objc func goForward(_ sender: Any?) {
        tabManager.selectedTab?.webView.goForward()
    }

    @objc func selectNextTab(_ sender: Any?) {
        tabManager.selectAdjacentTab(offset: 1)
    }

    @objc func selectPreviousTab(_ sender: Any?) {
        tabManager.selectAdjacentTab(offset: -1)
    }
}
