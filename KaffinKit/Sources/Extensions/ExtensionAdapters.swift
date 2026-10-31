import AppKit
import BrowserCore
import Tabs
import WebKit

/// One browser window, as WebKit's extension runtime sees it.
@MainActor
final class ExtensionWindow: NSObject, WKWebExtensionWindow {
    let manager: TabManager
    weak var window: NSWindow?
    private weak var host: ExtensionHost?

    init(manager: TabManager, window: NSWindow?, host: ExtensionHost) {
        self.manager = manager
        self.window = window
        self.host = host
    }

    func tabs(for context: WKWebExtensionContext) -> [any WKWebExtensionTab] {
        guard let host else { return [] }
        return manager.tabs.map(host.adapter)
    }

    func activeTab(for context: WKWebExtensionContext) -> (any WKWebExtensionTab)? {
        manager.selectedTab.flatMap { host?.adapter(for: $0) }
    }

    func windowType(for context: WKWebExtensionContext) -> WKWebExtension.WindowType { .normal }

    func windowState(for context: WKWebExtensionContext) -> WKWebExtension.WindowState {
        guard let window else { return .normal }
        if window.isMiniaturized { return .minimized }
        return window.styleMask.contains(.fullScreen) ? .fullscreen : .normal
    }

    func isPrivate(for context: WKWebExtensionContext) -> Bool { false }

    func frame(for context: WKWebExtensionContext) -> CGRect { window?.frame ?? .zero }

    func screenFrame(for context: WKWebExtensionContext) -> CGRect { window?.screen?.frame ?? .zero }

    func focus(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        window?.makeKeyAndOrderFront(nil)
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        window?.close()
        completionHandler(nil)
    }
}

/// One tab, as WebKit's extension runtime sees it. Holds the tab weakly, because tabs can close at any time.
@MainActor
final class ExtensionTab: NSObject, WKWebExtensionTab {
    private weak var tab: Tabs.Tab?
    private weak var host: ExtensionHost?

    init(tab: Tabs.Tab, host: ExtensionHost) {
        self.tab = tab
        self.host = host
    }

    private var manager: TabManager? {
        tab.flatMap { host?.window(containing: $0)?.manager }
    }

    func window(for context: WKWebExtensionContext) -> (any WKWebExtensionWindow)? {
        tab.flatMap { host?.window(containing: $0) }
    }

    func indexInWindow(for context: WKWebExtensionContext) -> Int {
        manager?.tabs.firstIndex { $0 === tab } ?? 0
    }

    func webView(for context: WKWebExtensionContext) -> WKWebView? { tab?.webView }

    func title(for context: WKWebExtensionContext) -> String? { tab?.title }

    func url(for context: WKWebExtensionContext) -> URL? { tab?.url }

    func isPinned(for context: WKWebExtensionContext) -> Bool { tab?.isPinned ?? false }

    func isMuted(for context: WKWebExtensionContext) -> Bool { tab?.isMuted ?? false }

    func isSelected(for context: WKWebExtensionContext) -> Bool {
        tab != nil && manager?.selectedTabID == tab?.id
    }

    func isLoadingComplete(for context: WKWebExtensionContext) -> Bool { tab?.isLoading == false }

    func zoomFactor(for context: WKWebExtensionContext) -> Double { tab.map { Double($0.webView.pageZoom) } ?? 1 }

    /// Lets `activeTab` work: a click on the extension grants access to that one tab.
    func shouldGrantPermissionsOnUserGesture(for context: WKWebExtensionContext) -> Bool { true }

    func setPinned(_ pinned: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let tab, tab.isPinned != pinned { manager?.togglePin(tab.id) }
        completionHandler(nil)
    }

    func setMuted(_ muted: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        guard let tab, let manager, tab.isMuted != muted else {
            completionHandler(nil)
            return
        }
        Task {
            await manager.toggleMute(tab.id)
            completionHandler(nil)
        }
    }

    func setZoomFactor(_ zoomFactor: Double, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        tab?.webView.pageZoom = zoomFactor
        completionHandler(nil)
    }

    func loadURL(_ url: URL, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        tab?.load(url)
        completionHandler(nil)
    }

    func reload(fromOrigin: Bool, for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        _ = fromOrigin ? tab?.webView.reloadFromOrigin() : tab?.webView.reload()
        completionHandler(nil)
    }

    func goBack(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        tab?.webView.goBack()
        completionHandler(nil)
    }

    func goForward(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        tab?.webView.goForward()
        completionHandler(nil)
    }

    func activate(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let tab { manager?.select(tab.id) }
        completionHandler(nil)
    }

    func close(for context: WKWebExtensionContext, completionHandler: @escaping ((any Error)?) -> Void) {
        if let tab { manager?.close(tab.id) }
        completionHandler(nil)
    }
}
