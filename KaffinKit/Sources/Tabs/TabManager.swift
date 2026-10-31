import BrowserCore
import Foundation
import Observation
import WebKit

/// Owns the tabs of one window. Tab WebViews live here so SwiftUI redraws can never recreate them.
@MainActor
@Observable
public final class TabManager {
    public private(set) var tabs: [Tab] = []
    public private(set) var selectedTabID: Tab.ID?

    @ObservationIgnored public var onSelectionChange: ((Tab?) -> Void)?
    @ObservationIgnored public var onLastTabClosed: (() -> Void)?

    @ObservationIgnored private let factory: WebViewFactory
    @ObservationIgnored private var closedTabURLs: [URL] = []
    @ObservationIgnored private lazy var navigationManager = NavigationManager(tabManager: self)

    public init(factory: WebViewFactory) {
        self.factory = factory
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

    private func addTab(configuration: WKWebViewConfiguration?) -> Tab {
        let webView = factory.makeWebView(configuration: configuration)
        webView.navigationDelegate = navigationManager
        webView.uiDelegate = navigationManager
        let tab = Tab(webView: webView, state: .background)
        if let selectedIndex = tabs.firstIndex(where: { $0.id == selectedTabID }) {
            tabs.insert(tab, at: selectedIndex + 1)
        } else {
            tabs.append(tab)
        }
        return tab
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
        onSelectionChange?(tab)
    }

    public func close(_ id: Tab.ID) {
        guard let index = tabs.firstIndex(where: { $0.id == id }) else { return }
        let wasSelected = id == selectedTabID
        let tab = tabs.remove(at: index)
        if let url = tab.url { closedTabURLs.append(url) }
        tab.webView.stopLoading()
        tab.webView.navigationDelegate = nil
        tab.webView.uiDelegate = nil

        guard !tabs.isEmpty else {
            selectedTabID = nil
            onSelectionChange?(nil)
            onLastTabClosed?()
            return
        }
        if wasSelected {
            selectedTabID = nil
            select(tabs[min(index, tabs.count - 1)].id)
        }
    }

    public func closeOthers(than id: Tab.ID) {
        guard tabs.contains(where: { $0.id == id }) else { return }
        select(id)
        tabs.filter { $0.id != id }.forEach { close($0.id) }
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

    public func move(_ id: Tab.ID, to index: Int) {
        guard let from = tabs.firstIndex(where: { $0.id == id }) else { return }
        let tab = tabs.remove(at: from)
        tabs.insert(tab, at: min(index, tabs.count))
    }

    public func selectTab(at index: Int) {
        if tabs.indices.contains(index) { select(tabs[index].id) }
    }

    public func selectAdjacentTab(offset: Int) {
        guard let selectedTabID, let index = tabs.firstIndex(where: { $0.id == selectedTabID }) else { return }
        select(tabs[(index + offset + tabs.count) % tabs.count].id)
    }

    func tab(for webView: WKWebView) -> Tab? {
        tabs.first { $0.webView === webView }
    }

    func handleContentProcessTermination(of tab: Tab) {
        tab.transition(to: .failed)
        if tab.id == selectedTabID { recover(tab) }
    }

    func handleLoadFinished(of tab: Tab) {
        guard tab.state == .restoring else { return }
        tab.transition(to: tab.id == selectedTabID ? .active : .background)
    }

    private func recover(_ tab: Tab) {
        tab.transition(to: .restoring)
        tab.webView.reload()
    }
}
