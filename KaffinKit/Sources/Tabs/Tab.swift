import BrowserCore
import Foundation
import Observation
import WebKit

@MainActor
@Observable
public final class Tab: Identifiable {
    public let id = UUID()
    /// Replaced while the tab sleeps, so keep no long-lived reference to it.
    public private(set) var webView: WKWebView
    public private(set) var state: TabLifecycleState
    public private(set) var title: String?
    public private(set) var url: URL?
    public private(set) var isLoading = false
    public private(set) var canGoBack = false
    public private(set) var canGoForward = false
    /// The URL stays in the address bar, so the security indicator must not vouch for this page.
    public internal(set) var isShowingError = false
    public internal(set) var loginPrompt: LoginPrompt?
    /// PNG data of the site's icon.
    public internal(set) var favicon: Data?
    /// Camera or microphone is live right now, which the address bar always shows.
    public internal(set) var isCapturing = false
    public internal(set) var isPinned = false
    public internal(set) var isMuted = false
    @ObservationIgnored var faviconHost: String?
    /// When the user last left this tab, for idle sleeping.
    @ObservationIgnored var lastActiveAt = Date.now

    var loginOrigin: String? { LoginOrigin.make(from: webView.url) }

    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var pending: SessionTab?
    @ObservationIgnored var onTitleChange: ((URL, String) -> Void)?
    @ObservationIgnored var onPropertiesChange: (() -> Void)?

    /// True for a restored tab whose page has not started loading yet.
    public var isAwaitingLoad: Bool { pending != nil }

    init(webView: WKWebView, state: TabLifecycleState, restoring session: SessionTab? = nil) {
        self.webView = webView
        self.state = state
        pending = session
        isPinned = session?.isPinned ?? false
        title = session?.title
        url = session?.url
        observeWebView()
    }

    private func observeWebView() {
        observations = [
            observe(\.title) { tab, webView in
                // A restored tab keeps its saved title until its page starts loading.
                guard !tab.isAwaitingLoad else { return }
                tab.title = webView.title.flatMap { $0.isEmpty ? nil : $0 }
                tab.onPropertiesChange?()
                if !tab.isShowingError, let url = webView.url, let title = tab.title { tab.onTitleChange?(url, title) }
            },
            observe(\.url) { tab, webView in
                if !tab.isAwaitingLoad { tab.url = webView.url }
                tab.onPropertiesChange?()
            },
            observe(\.isLoading) { tab, webView in
                tab.isLoading = webView.isLoading
                tab.onPropertiesChange?()
            },
            observe(\.cameraCaptureState) { $0.isCapturing = $1.cameraCaptureState == .active || $1.microphoneCaptureState == .active },
            observe(\.microphoneCaptureState) { $0.isCapturing = $1.cameraCaptureState == .active || $1.microphoneCaptureState == .active },
            observe(\.canGoBack) { $0.canGoBack = $1.canGoBack },
            observe(\.canGoForward) { $0.canGoForward = $1.canGoForward },
        ]
    }

    private func observe<Value>(
        _ keyPath: KeyPath<WKWebView, Value>,
        update: @escaping @MainActor (Tab, WKWebView) -> Void
    ) -> NSKeyValueObservation {
        webView.observe(keyPath, options: [.initial]) { [weak self] webView, _ in
            // WKWebView posts these on the main thread.
            MainActor.assumeIsolated {
                if let self { update(self, webView) }
            }
        }
    }

    /// Returns false and leaves the state unchanged when the transition is invalid.
    @discardableResult
    func transition(to next: TabLifecycleState) -> Bool {
        guard state.canTransition(to: next) else { return false }
        state = next
        return true
    }

    public func load(_ url: URL) {
        pending = nil
        webView.load(URLRequest(url: url))
    }

    func startPendingLoad() {
        guard let pending else { return }
        self.pending = nil
        if let state = pending.interactionState { webView.interactionState = state }
        // An empty saved state leaves nothing to navigate to, and the tab would stay blank.
        if webView.backForwardList.currentItem == nil { webView.load(URLRequest(url: pending.url)) }
    }

    /// Swaps in a WebView with no page, so WebKit can free the old page's memory.
    /// The saved state stays in memory only, which keeps private tabs off the disk.
    func fallAsleep(into replacement: WKWebView) {
        pending = sessionTab(isSelected: false)
        let old = webView
        old.stopLoading()
        old.navigationDelegate = nil
        old.uiDelegate = nil
        old.removeFromSuperview()
        webView = replacement
        observeWebView()
        transition(to: .sleeping)
    }

    func sessionTab(isSelected: Bool) -> SessionTab? {
        guard let url else { return nil }
        // WebKit documents the value as opaque; a test pins that it is Data on the supported macOS.
        let state = pending?.interactionState ?? webView.interactionState as? Data
        return SessionTab(url: url, title: title, isSelected: isSelected, interactionState: state, isPinned: isPinned)
    }
}
