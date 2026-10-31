import BrowserCore
import Foundation
import OSLog
import Observation
import WebKit

/// Owns the tabs of one window. Tab WebViews live here so SwiftUI redraws can never recreate them.
@MainActor
@Observable
public final class TabManager {
    private static let logger = Logger(subsystem: "com.kaffin.browser", category: "Tabs")

    public private(set) var tabs: [Tab] = []
    public private(set) var selectedTabID: Tab.ID?

    @ObservationIgnored public var onSelectionChange: ((Tab?) -> Void)?
    @ObservationIgnored public var onLastTabClosed: (() -> Void)?
    /// Fires for anything a saved session must reflect.
    @ObservationIgnored public var onChange: (() -> Void)?
    @ObservationIgnored public var onPageVisit: ((URL, String?) -> Void)?
    @ObservationIgnored public var onPageTitle: ((URL, String) -> Void)?
    @ObservationIgnored public var onMoveToNewWindow: ((Tab.ID) -> Void)?

    @ObservationIgnored private let factory: WebViewFactory
    @ObservationIgnored private var closedTabURLs: [URL] = []
    @ObservationIgnored private lazy var navigationManager = NavigationManager(tabManager: self)

    @ObservationIgnored let downloads: DownloadManager
    @ObservationIgnored private let credentials: (any CredentialStoring)?
    @ObservationIgnored private let favicons: FaviconLoader?
    @ObservationIgnored private lazy var loginBridge = LoginBridge(tabManager: self)

    /// Without credentials, as in private windows, no login script runs at all.
    public init(
        factory: WebViewFactory,
        downloads: DownloadManager = DownloadManager(),
        credentials: (any CredentialStoring)? = nil,
        favicons: FaviconLoader? = nil
    ) {
        self.favicons = favicons
        self.factory = factory
        self.downloads = downloads
        self.credentials = credentials
    }

    public var selectedTab: Tab? {
        tabs.first { $0.id == selectedTabID }
    }

    @discardableResult
    public func newTab(url: URL? = nil, select: Bool = true) -> Tab {
        let tab = addTab(configuration: nil)
        if let url { tab.load(url) }
        if select { self.select(tab.id) }
        return tab
    }

    /// Opens a tab with WebKit's configuration, for `window.open` and `target=_blank`.
    func addPopupTab(configuration: WKWebViewConfiguration) -> Tab {
        let tab = addTab(configuration: configuration)
        select(tab.id)
        return tab
    }

    public func restore(_ window: SessionWindow) {
        for session in window.tabs {
            addTab(configuration: nil, restoring: session)
        }
        let selected = window.tabs.firstIndex(where: \.isSelected) ?? 0
        if tabs.indices.contains(selected) { select(tabs[selected].id) }
    }

    public func snapshot() -> SessionWindow {
        SessionWindow(tabs: tabs.compactMap { $0.sessionTab(isSelected: $0.id == selectedTabID) })
    }

    @discardableResult
    private func addTab(configuration: WKWebViewConfiguration?, restoring session: SessionTab? = nil) -> Tab {
        let webView = factory.makeWebView(configuration: configuration)
        webView.navigationDelegate = navigationManager
        webView.uiDelegate = navigationManager
        // A popup's configuration comes from its opener, which already has the bridge.
        if credentials != nil, configuration == nil {
            loginBridge.install(on: webView.configuration.userContentController)
        }
        let tab = Tab(webView: webView, state: .background, restoring: session)
        connectTitle(of: tab)
        if let favicons, let key = session.flatMap({ Self.faviconKey(for: $0.url) }) {
            tab.faviconHost = key
            Task { tab.favicon = await favicons.cached(host: key) }
        }
        if let selectedIndex = tabs.firstIndex(where: { $0.id == selectedTabID }) {
            tabs.insert(tab, at: max(selectedIndex + 1, pinnedCount))
        } else {
            tabs.append(tab)
        }
        onChange?()
        return tab
    }

    private func connectTitle(of tab: Tab) {
        tab.onTitleChange = { [weak self] url, title in self?.onPageTitle?(url, title) }
    }

    public func select(_ id: Tab.ID) {
        guard id != selectedTabID, let tab = tabs.first(where: { $0.id == id }) else { return }
        selectedTab?.transition(to: .background)
        selectedTabID = id
        if tab.state == .failed {
            recover(tab)
        } else {
            tab.transition(to: .active)
        }
        tab.startPendingLoad()
        onSelectionChange?(tab)
        onChange?()
    }

    public func close(_ id: Tab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = id == selectedTabID
        let tab = tabs.remove(at: index)
        if let url = tab.url { closedTabURLs.append(url) }
        tab.webView.stopLoading()
        tab.webView.navigationDelegate = nil
        tab.webView.uiDelegate = nil
        onChange?()

        guard !tabs.isEmpty else {
            selectedTabID = nil
            onSelectionChange?(nil)
            onLastTabClosed?()
            return
        }
        if wasSelected { selectNeighbor(of: index) }
    }

    private func selectNeighbor(of index: Int) {
        selectedTabID = nil
        select(tabs[min(index, tabs.count - 1)].id)
    }

    /// Takes a tab out with its page still running. The only tab stays, since a window needs one.
    public func detachTab(_ id: Tab.ID) -> Tab? {
        guard tabs.count > 1, let index = tabs.firstIndex(where: { $0.id == id }) else { return nil }
        let wasSelected = id == selectedTabID
        let tab = tabs.remove(at: index)
        tab.transition(to: .background)
        onChange?()
        if wasSelected { selectNeighbor(of: index) }
        return tab
    }

    /// Takes over a tab from another window of the same profile, without reloading its page.
    public func adopt(_ tab: Tab) {
        tab.webView.navigationDelegate = navigationManager
        tab.webView.uiDelegate = navigationManager
        if credentials != nil { loginBridge.takeOver(tab.webView.configuration.userContentController) }
        connectTitle(of: tab)
        tabs.insert(tab, at: tab.isPinned ? pinnedCount : tabs.count)
        select(tab.id)
    }

    public func closeOthers(than id: Tab.ID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        select(id)
        tabs.filter { $0.id != id && !$0.isPinned }.forEach { close($0.id) }
    }

    /// Reopens by URL only; closed tabs keep no back/forward history yet.
    @discardableResult
    public func reopenClosedTab() -> Tab? {
        closedTabURLs.popLast().map { newTab(url: $0) }
    }

    public func duplicate(_ id: Tab.ID) {
        guard let url = tabs.first(where: { $0.id == id })?.url else { return }
        select(id)
        newTab(url: url)
    }

    private var pinnedCount: Int {
        tabs.prefix { $0.isPinned }.count
    }

    /// The positions a tab may take: pinned tabs stay before all others.
    public func moveRange(of tab: Tab) -> ClosedRange<Int> {
        tab.isPinned ? 0...max(0, pinnedCount - 1) : pinnedCount...max(pinnedCount, tabs.count - 1)
    }

    public func move(_ id: Tab.ID, to index: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let range = moveRange(of: tabs[from])
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: min(range.upperBound, max(range.lowerBound, index)))
        onChange?()
    }

    public func togglePin(_ id: Tab.ID) {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: from)
        tab.isPinned.toggle()
        tabs.insert(tab, at: pinnedCount)
        onChange?()
    }

    public func toggleMute(_ id: Tab.ID) async {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        tab.isMuted.toggle()
        await TabAudioMuter.apply(muted: tab.isMuted, to: tab.webView)
    }

    public func selectTab(at index: Int) {
        if tabs.indices.contains(index) { select(tabs[index].id) }
    }

    public func selectAdjacentTab(offset: Int) {
        guard let selectedTabID, let index = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }
        select(tabs[(index + offset + tabs.count) % tabs.count].id)
    }

    func offerSavedLogins(on tab: Tab, origin: String) async {
        guard tab.loginPrompt == nil, let logins = try? await credentials?.logins(for: origin), !logins.isEmpty else {
            return
        }
        if tab.loginPrompt == nil, tab.loginOrigin == origin { tab.loginPrompt = .fill(logins) }
    }

    func offerToSave(_ login: SavedLogin, password: String, on tab: Tab) async {
        guard let credentials else { return }
        let existing = try? await credentials.password(for: login)
        if existing != password {
            tab.loginPrompt = .save(login, password: password, isUpdate: existing != nil)
        }
    }

    public func acceptLoginPrompt(on tab: Tab) async {
        guard case .save(let login, let password, _) = tab.loginPrompt else { return }
        do {
            try await credentials?.save(login, password: password)
            tab.loginPrompt = nil
        } catch {
            // The prompt stays up, so the password is not lost without the user knowing.
            Self.logger.error("Could not save login: \(String(describing: error), privacy: .public)")
        }
    }

    public func dismissLoginPrompt(on tab: Tab) {
        tab.loginPrompt = nil
    }

    public func fill(_ login: SavedLogin, on tab: Tab) async {
        guard tab.loginOrigin == login.origin,
              let password = try? await credentials?.password(for: login),
              tab.loginOrigin == login.origin else { return }
        tab.loginPrompt = nil
        _ = try? await tab.webView.callAsyncJavaScript(
            LoginBridge.fillScript,
            arguments: ["username": login.username, "secret": password],
            contentWorld: LoginBridge.world
        )
    }

    func tab(for webView: WKWebView) -> Tab? {
        tabs.first { $0.webView === webView }
    }

    func handleContentProcessTermination(of tab: Tab) {
        tab.transition(to: .failed)
        if tab.id == selectedTabID { recover(tab) }
    }

    func handleLoadFinished(of tab: Tab) {
        if tab.isMuted {
            Task { await TabAudioMuter.apply(muted: true, to: tab.webView) }
        }
        if !tab.isShowingError, let url = tab.webView.url {
            onPageVisit?(url, tab.webView.title)
            Task { await loadFavicon(for: tab, url: url) }
        }
        onChange?()
        guard tab.state == .restoring else { return }
        tab.transition(to: tab.id == selectedTabID ? .active : .background)
    }

    /// Includes the port, because local sites on different ports are different sites.
    private static func faviconKey(for url: URL) -> String? {
        guard url.scheme == "https" || url.scheme == "http", let host = url.host() else { return nil }
        return url.port.map { "\(host):\($0)" } ?? host
    }

    func handleCommit(of tab: Tab) {
        // Hooks the new document early, so a muted tab's next page does not start playing with sound.
        if tab.isMuted {
            Task { await TabAudioMuter.apply(muted: true, to: tab.webView) }
        }
        let key = tab.webView.url.flatMap(Self.faviconKey)
        if key != tab.faviconHost {
            tab.faviconHost = key
            tab.favicon = nil
        }
    }

    private func loadFavicon(for tab: Tab, url: URL) async {
        guard let favicons, let key = Self.faviconKey(for: url) else { return }
        if let icon = await favicons.cached(host: key) {
            if tab.faviconHost == key { tab.favicon = icon }
            return
        }
        // The default client world, so page scripts cannot tamper with the lookup.
        let declared = try? await tab.webView.callAsyncJavaScript(
            "return [...document.querySelectorAll('link[rel~=\"icon\"]')].map((link) => link.href)",
            contentWorld: .defaultClient
        ) as? [String]
        var candidates = (declared ?? []).compactMap(URL.init(string:))
        if let fallback = URL(string: "/favicon.ico", relativeTo: url)?.absoluteURL { candidates.append(fallback) }
        let icon = await favicons.icon(host: key, candidates: candidates)
        if tab.faviconHost == key { tab.favicon = icon }
    }

    private func recover(_ tab: Tab) {
        tab.transition(to: .restoring)
        tab.webView.reload()
    }
}
