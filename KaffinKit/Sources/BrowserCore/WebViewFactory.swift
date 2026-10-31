import Foundation
import WebKit

/// The only place that builds WebKit configurations and WebViews, so every tab shares the same policies.
@MainActor
public final class WebViewFactory {
    public static let defaultProfileID = UUID(uuidString: "6F1C2A54-0D3B-4C7E-9A11-3E5B7C9D1F20")!

    private let dataStore: WKWebsiteDataStore

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

    /// WKWebView's default user agent has no Safari token, which some sites read as an embedded view.
    public static var userAgentToken: String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        return "Version/\(os.majorVersion).\(os.minorVersion) Safari/605.1.15"
    }

    public func makeConfiguration() -> WKWebViewConfiguration {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.applicationNameForUserAgent = Self.userAgentToken
        configuration.preferences.isFraudulentWebsiteWarningEnabled = true
        configuration.preferences.isElementFullscreenEnabled = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        return configuration
    }

    /// Pass WebKit's own configuration for popups, which must be used unchanged.
    public func makeWebView(configuration: WKWebViewConfiguration? = nil) -> WKWebView {
        let webView = WKWebView(frame: .zero, configuration: configuration ?? makeConfiguration())
        webView.allowsBackForwardNavigationGestures = true
        #if DEBUG
        webView.isInspectable = true
        #endif
        return webView
    }
}
