import AppKit
import Foundation
import WebKit

/// A WKWebView whose right-click menu can gain items, which is how extensions reach it.
final class BrowserWebView: WKWebView {
    var extraMenuItems: ((WKWebView) -> [NSMenuItem])?

    override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        super.willOpenMenu(menu, with: event)
        let items = extraMenuItems?(self) ?? []
        if !items.isEmpty { menu.addItem(.separator()) }
        items.forEach(menu.addItem)
    }
}

/// The only place that builds WebKit configurations and WebViews, so every tab shares the same policies.
@MainActor
public final class WebViewFactory {
    public static let defaultProfileID = UUID(uuidString: "6F1C2A54-0D3B-4C7E-9A11-3E5B7C9D1F20")!

    public let dataStore: WKWebsiteDataStore
    /// Set for a profile's normal windows. Private windows have none, so extensions never see them.
    public var extensionController: WKWebExtensionController?
    public var pageMenuItems: ((WKWebView) -> [NSMenuItem])?

    public init(profileID: UUID = WebViewFactory.defaultProfileID) {
        dataStore = WKWebsiteDataStore(forIdentifier: profileID)
    }

    private init(dataStore: WKWebsiteDataStore) {
        self.dataStore = dataStore
    }

    /// Website data lives only as long as the returned factory and its WebViews.
    public static func privateSession() -> WebViewFactory {
        WebViewFactory(dataStore: .nonPersistent())
    }

    /// WebKit refuses while a WebView still uses the store, so closing windows first is not always enough at once.
    public static func removeProfileData(_ id: UUID) async throws {
        for attempt in 1...10 {
            do {
                return try await WKWebsiteDataStore.remove(forIdentifier: id)
            } catch where attempt < 10 {
                try await Task.sleep(for: .milliseconds(300))
            }
        }
    }

    /// WKWebView's default user agent has no Safari token, which some sites read as an embedded view.
    public static var userAgentToken: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "Version/\(os.majorVersion).\(os.minorVersion) Safari/605.1.15"
    }

    public func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.webExtensionController = extensionController
        configuration.applicationNameForUserAgent = Self.userAgentToken
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        return configuration
    }

    /// Pass WebKit's own configuration for popups, which must be used unchanged.
    public func makeWebView(configuration: WKWebViewConfiguration? = nil) -> WKWebView {
        let webView = BrowserWebView(frame: .zero, configuration: configuration ?? makeConfiguration())
        webView.extraMenuItems = { [weak self] in self?.pageMenuItems?($0) ?? [] }
        webView.allowsBackForwardNavigationGestures = true
        #if DEBUG
        webView.isInspectable = true
        #endif
        return webView
    }
}
