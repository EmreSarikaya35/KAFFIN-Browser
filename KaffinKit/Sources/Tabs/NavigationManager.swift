import AppKit
import BrowserCore
import WebKit

/// Central WebKit delegate for one window's tabs.
@MainActor
final class NavigationManager: NSObject, WKNavigationDelegate, WKUIDelegate {
    private static let webSchemes: Set<String> = ["http", "https", "about", "blob", "data"]

    private unowned let tabManager: TabManager
    private var errorPageWebViews: Set<ObjectIdentifier> = []

    init(tabManager: TabManager) {
        self.tabManager = tabManager
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        if let tab = tabManager.tab(for: webView) {
            tabManager.handleContentProcessTermination(of: tab)
        }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        guard let tab = tabManager.tab(for: webView) else { return }
        tabManager.handleCommit(of: tab)
        tab.isShowingError = errorPageWebViews.remove(ObjectIdentifier(webView)) != nil
        // A fill offer belongs to the page that showed it; a save offer must outlive the login redirect.
        if case .fill = tab.loginPrompt { tab.loginPrompt = nil }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        if let tab = tabManager.tab(for: webView) {
            tabManager.handleLoadFinished(of: tab)
        }
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        showErrorPage(in: webView, for: error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        showErrorPage(in: webView, for: error)
    }

    private func showErrorPage(in webView: WKWebView, for error: Error) {
        guard ErrorPage.shouldShow(for: error) else { return }
        let failed = (error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL ?? webView.url
        guard let failed else { return }
        errorPageWebViews.insert(ObjectIdentifier(webView))
        // A simulated load keeps the failed address, so Reload retries the real page.
        webView.loadSimulatedRequest(
            URLRequest(url: failed),
            responseHTML: ErrorPage.html(host: failed.host() ?? failed.absoluteString, message: error.localizedDescription)
        )
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor action: WKNavigationAction
    ) async -> WKNavigationActionPolicy {
        if action.shouldPerformDownload { return .download }
        guard let url = action.request.url, let scheme = url.scheme?.lowercased() else { return .allow }
        if Self.webSchemes.contains(scheme) { return .allow }
        // mailto: and similar need another app. Requiring a click stops pages launching apps on their own.
        if action.navigationType == .linkActivated { NSWorkspace.shared.open(url) }
        return .cancel
    }

    func webView(
        _ webView: WKWebView,
        decidePolicyFor response: WKNavigationResponse
    ) async -> WKNavigationResponsePolicy {
        let disposition = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition")
        let download = DownloadRules.shouldDownload(
            canShowMIMEType: response.canShowMIMEType,
            contentDisposition: disposition
        )
        return download && response.isForMainFrame ? .download : .allow
    }

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) {
        tabManager.downloads.attach(download)
    }

    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) {
        tabManager.downloads.attach(download)
    }

    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        tabManager.addPopupTab(configuration: configuration).webView
    }

    func webView(
        _ webView: WKWebView,
        runOpenPanelWith parameters: WKOpenPanelParameters,
        initiatedByFrame frame: WKFrameInfo
    ) async -> [URL]? {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = parameters.allowsMultipleSelection
        panel.canChooseDirectories = parameters.allowsDirectories
        return await panel.begin() == .OK ? panel.urls : nil
    }
}
