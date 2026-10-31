import WebKit

/// Central WebKit delegate for one window's tabs.
// shortcut: downloads, non-web schemes and error pages use WebKit defaults, added in Phase 3.
@MainActor
final class NavigationManager: NSObject, WKNavigationDelegate, WKUIDelegate {
    private unowned let tabManager: TabManager

    init(tabManager: TabManager) {
        self.tabManager = tabManager
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if let tab = tabManager.tab(for: webView) {
            tabManager.handleContentProcessTermination(of: tab)
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let tab = tabManager.tab(for: webView) {
            tabManager.handleLoadFinished(of: tab)
        }
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        tabManager.addPopupTab(configuration: configuration).webView
    }
}
