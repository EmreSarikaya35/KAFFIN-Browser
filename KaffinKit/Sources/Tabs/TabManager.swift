import BrowserCore
import Foundation
import OSLog
import Observation
import WebKit

/// What other parts of the browser, like extensions, may react to.
public enum TabEvent {
    case opened(Tab)
    case closed(Tab)
    case selected(Tab, previous: Tab?)
    case moved(Tab, from: Int)
    case changed(Tab)
}

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
    @ObservationIgnored public var onTabEvent: ((TabEvent) -> Void)?
    @ObservationIgnored public weak var dialogs: (any PageDialogPresenting)?

    @ObservationIgnored private let factory: WebViewFactory
    @ObservationIgnored private var closedTabURLs: [URL] = []
    @ObservationIgnored private lazy var navigationManager = NavigationManager(tabManager: self)

    @ObservationIgnored let downloads: DownloadManager
    @ObservationIgnored private let credentials: (any CredentialStoring)?
    @ObservationIgnored private let favicons: FaviconLoader?
    @ObservationIgnored private let sitePermissions: (any SitePermissionStoring)?
    @ObservationIgnored private lazy var loginBridge = LoginBridge(tabManager: self)
    @ObservationIgnored private lazy var locationBridge = LocationBridge(tabManager: self)

    /// Without credentials, as in private windows, no login script runs at all.
    public init(
        factory: WebViewFactory,
        downloads: DownloadManager = DownloadManager(),
        credentials: (any CredentialStoring)? = nil,
        favicons: FaviconLoader? = nil,
        sitePermissions: (any SitePermissionStoring)? = nil
    ) {
        self.sitePermissions = sitePermissions
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

    /// Keeps one tab per page, and uses an empty tab instead of adding another, like Chrome.
    public func showInternalPage(_ page: InternalPage) {
        if let open = tabs.first(where: { $0.internalPage == page }) {
            select(open.id)
        } else if let tab = selectedTab, tab.url == nil {
            tab.load(page.url)
        } else {
            newTab(url: page.url)
        }
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
        let webView = makeWebView(configuration: configuration)
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
        onTabEvent?(.opened(tab))
        return tab
    }

    private func makeWebView(configuration: WKWebViewConfiguration?) -> WKWebView {
        let webView = factory.makeWebView(configuration: configuration)
        webView.navigationDelegate = navigationManager
        webView.uiDelegate = navigationManager
        // A popup's configuration comes from its opener, which already has the bridges.
        if configuration == nil {
            locationBridge.install(on: webView.configuration.userContentController)
            if credentials != nil { loginBridge.install(on: webView.configuration.userContentController) }
        }
        return webView
    }

    private func connectTitle(of tab: Tab) {
        tab.onTitleChange = { [weak self] url, title in self?.onPageTitle?(url, title) }
        tab.onPropertiesChange = { [weak self, weak tab] in
            if let tab { self?.onTabEvent?(.changed(tab)) }
        }
    }

    public func select(_ id: Tab.ID) {
        guard id != selectedTabID, let tab = tabs.first(where: { $0.id == id }) else { return }
        let previous = selectedTab
        if let previous {
            previous.lastActiveAt = .now
            previous.transition(to: .background)
        }
        selectedTabID = id
        switch tab.state {
        case .failed: recover(tab)
        case .sleeping: tab.transition(to: .restoring)
        default: tab.transition(to: .active)
        }
        tab.startPendingLoad()
        onSelectionChange?(tab)
        onChange?()
        onTabEvent?(.selected(tab, previous: previous))
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
        onTabEvent?(.closed(tab))

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
        onTabEvent?(.closed(tab))
        if wasSelected { selectNeighbor(of: index) }
        return tab
    }

    /// Takes over a tab from another window of the same profile, without reloading its page.
    public func adopt(_ tab: Tab) {
        tab.webView.navigationDelegate = navigationManager
        tab.webView.uiDelegate = navigationManager
        locationBridge.takeOver(tab.webView.configuration.userContentController)
        if credentials != nil { loginBridge.takeOver(tab.webView.configuration.userContentController) }
        connectTitle(of: tab)
        tabs.insert(tab, at: tab.isPinned ? pinnedCount : tabs.count)
        onTabEvent?(.opened(tab))
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
        onTabEvent?(.moved(tab, from: from))
    }

    public func togglePin(_ id: Tab.ID) {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: from)
        tab.isPinned.toggle()
        tabs.insert(tab, at: pinnedCount)
        onChange?()
        onTabEvent?(.changed(tab))
    }

    public func toggleMute(_ id: Tab.ID) async {
        guard let tab = tabs.first(where: { $0.id == id }) else { return }
        tab.isMuted.toggle()
        onTabEvent?(.changed(tab))
        await TabAudioMuter.apply(muted: tab.isMuted, to: tab.webView)
    }

    /// Keeps the tab in the strip and frees its page. Selecting it loads the page again.
    @discardableResult
    public func sleep(_ id: Tab.ID) -> Bool {
        guard id != selectedTabID, let tab = tabs.first(where: { $0.id == id }),
              tab.state == .background, tab.url != nil, tab.internalPage == nil else { return false }
        if tab.isAwaitingLoad {
            tab.transition(to: .sleeping)
        } else {
            tab.fallAsleep(into: makeWebView(configuration: nil))
        }
        onChange?()
        return true
    }

    /// Automatic sleeping starts and stops here: without a profile that allows the trigger, nothing happens.
    public func sleepEligibleTabs(_ settings: PerformanceSettings, trigger: SleepTrigger, now: Date = .now) async {
        let isAllowed = trigger == .idle ? settings.sleepsIdleTabs : settings.sleepsUnderMemoryPressure
        guard isAllowed else { return }
        for tab in tabs where tab.id != selectedTabID && tab.state == .background && !tab.isAwaitingLoad && tab.internalPage == nil {
            let webView = tab.webView
            let media = await webView.requestMediaPlaybackState()
            let candidate = SleepCandidate(
                lastActiveAt: tab.lastActiveAt,
                isPinned: tab.isPinned,
                host: webView.url.flatMap(SiteMatch.siteHost),
                // Any media counts: WebKit's playing and paused states proved unreliable in testing.
                hasMedia: media != .none,
                isCapturing: webView.cameraCaptureState != .none || webView.microphoneCaptureState != .none,
                hasActiveDownload: downloads.hasActiveDownload(in: webView),
                hasLoginPrompt: tab.loginPrompt != nil
            )
            let allowed = SleepPolicy.allows(
                candidate,
                idleMinutes: settings.idleMinutes,
                protectsPinnedTabs: settings.protectsPinnedTabs,
                excludedSites: settings.excludedSites,
                requiringIdle: trigger == .idle,
                now: now
            )
            if allowed { sleep(tab.id) }
        }
    }

    public func selectTab(at index: Int) {
        if tabs.indices.contains(index) { select(tabs[index].id) }
    }

    public func selectAdjacentTab(offset: Int) {
        guard let selectedTabID, let index = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }
        select(tabs[(index + offset + tabs.count) % tabs.count].id)
    }

    /// Without a store, as in private windows, every request asks again and nothing is kept.
    func decidePermission(_ kind: SitePermissionKind, site: String) async -> Bool {
        var isAllowed: Bool
        if let stored = try? await sitePermissions?.sitePermission(kind, site: site) {
            isAllowed = stored
        } else {
            let answer = await dialogs?.askPermission(kind, for: site) ?? .notNow
            if answer != .notNow {
                try? await sitePermissions?.setSitePermission(kind, site: site, allowed: answer == .allow)
            }
            isAllowed = answer == .allow
        }
        // The site's permission is useless until macOS also lets KAFFIN read the location.
        if isAllowed, kind == .location { isAllowed = await dialogs?.ensureSystemLocationAccess() ?? false }
        return isAllowed
    }

    func offerSavedLogins(on tab: Tab, origin: String) async {
        guard BrowserPreferences.shared.offersToFillPasswords, tab.loginPrompt == nil, let logins = try? await credentials?.logins(for: origin), !logins.isEmpty else {
            return
        }
        if tab.loginPrompt == nil, tab.loginOrigin == origin { tab.loginPrompt = .fill(logins) }
    }

    func offerToSave(_ login: SavedLogin, password: String, on tab: Tab) async {
        guard let credentials, BrowserPreferences.shared.offersToSavePasswords else { return }
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
