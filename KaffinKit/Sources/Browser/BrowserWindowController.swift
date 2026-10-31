import AppKit
import BrowserCore
import BrowserUI
import SwiftUI
import Tabs

@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    private let tabManager: TabManager
    private let bookmarks: BookmarksModel
    let isPrivate: Bool
    private let webContainer = NSView()
    private var newTabHost: NSHostingView<NewTabView>!
    private var chromeHost: NSHostingView<BrowserChromeView>!
    private var focusRequest = 0
    var onClose: ((BrowserWindowController) -> Void)?
    var onNewWindow: (() -> Void)?
    var onNewPrivateWindow: (() -> Void)?
    var onShowHistory: (() -> Void)?
    private var chromeHeight: NSLayoutConstraint!

    /// Private windows get their own factory, and the caller wires no session or history saving.
    init(factory: WebViewFactory, bookmarks: BookmarksModel, isPrivate: Bool, session: SessionWindow?) {
        tabManager = TabManager(factory: factory)
        self.bookmarks = bookmarks
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
        installContent(in: window)
        tabManager.onSelectionChange = { [weak self] in self?.show($0) }
        tabManager.onLastTabClosed = { [weak self] in self?.window?.close() }
        if let session, !session.tabs.isEmpty {
            tabManager.restore(session)
        } else {
            tabManager.newTab()
        }
        updateNewTabPage()
        updateChromeHeight()
    }

    var snapshot: SessionWindow { tabManager.snapshot() }

    func trackChanges(onChange: @escaping () -> Void, onPageVisit: @escaping (URL, String?) -> Void) {
        tabManager.onChange = onChange
        tabManager.onPageVisit = onPageVisit
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
        chromeHeight = chromeHost.heightAnchor.constraint(equalToConstant: BrowserChromeView.height)
        webContainer.translatesAutoresizingMaskIntoConstraints = false
        newTabHost = NSHostingView(rootView: NewTabView { [weak self] in self?.submitAddress($0) })
        newTabHost.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(webContainer)
        content.addSubview(newTabHost)
        content.addSubview(chromeHost)
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
        ])
    }

    private func makeChromeView() -> BrowserChromeView {
        BrowserChromeView(
            tabManager: tabManager,
            bookmarks: bookmarks,
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

    private func updateChromeHeight() {
        let isBarVisible = withObservationTracking {
            bookmarks.isBarVisible
        } onChange: { [weak self] in
            Task { @MainActor in self?.updateChromeHeight() }
        }
        chromeHeight.constant = BrowserChromeView.height + (isBarVisible ? BrowserChromeView.bookmarksBarHeight : 0)
    }

    private func submitAddress(_ text: String) {
        guard let url = AddressResolver.resolve(text), let tab = tabManager.selectedTab else { return }
        tab.load(url)
        window?.makeFirstResponder(tab.webView)
    }

    private func focusAddressBar() {
        focusRequest += 1
        chromeHost.rootView = makeChromeView()
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
