import AppKit
import BrowserCore
import BrowserUI
import SwiftUI
import Tabs

@MainActor
final class BrowserWindowController: NSWindowController, NSWindowDelegate {
    private let tabManager: TabManager
    private let webContainer = NSView()
    private var chromeHost: NSHostingView<BrowserChromeView>!
    private var focusRequest = 0
    var onClose: ((BrowserWindowController) -> Void)?

    init(factory: WebViewFactory) {
        tabManager = TabManager(factory: factory)
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
        window.setFrameAutosaveName("BrowserWindow")
        super.init(window: window)

        window.delegate = self
        installContent(in: window)
        tabManager.onSelectionChange = { [weak self] in self?.show($0) }
        tabManager.onLastTabClosed = { [weak self] in self?.window?.close() }
        tabManager.newTab()
        focusAddressBar()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    private func installContent(in window: NSWindow) {
        guard let content = window.contentView else { return }
        chromeHost = NSHostingView(rootView: makeChromeView())
        chromeHost.translatesAutoresizingMaskIntoConstraints = false
        webContainer.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(webContainer)
        content.addSubview(chromeHost)
        NSLayoutConstraint.activate([
            chromeHost.topAnchor.constraint(equalTo: content.topAnchor),
            chromeHost.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            chromeHost.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            chromeHost.heightAnchor.constraint(equalToConstant: BrowserChromeView.height),
            webContainer.topAnchor.constraint(equalTo: chromeHost.bottomAnchor),
            webContainer.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            webContainer.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            webContainer.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    private func makeChromeView() -> BrowserChromeView {
        BrowserChromeView(tabManager: tabManager, focusRequest: focusRequest) { [weak self] in
            self?.submitAddress($0)
        }
    }

    private func show(_ tab: Tabs.Tab?) {
        webContainer.subviews.forEach { $0.removeFromSuperview() }
        guard let tab else { return }
        tab.webView.frame = webContainer.bounds
        tab.webView.autoresizingMask = [.width, .height]
        webContainer.addSubview(tab.webView)
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
        focusAddressBar()
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
