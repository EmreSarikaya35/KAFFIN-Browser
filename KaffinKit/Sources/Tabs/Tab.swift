import BrowserCore
import Foundation
import Observation
import WebKit

@MainActor
@Observable
public final class Tab: Identifiable {
    public let id = UUID()
    public let webView: WKWebView
    public private(set) var state: TabLifecycleState
    public private(set) var title: String?
    public private(set) var url: URL?
    public private(set) var isLoading = false
    public private(set) var canGoBack = false
    public private(set) var canGoForward = false
    /// The URL stays in the address bar, so the security indicator must not vouch for this page.
    public internal(set) var isShowingError = false
    public internal(set) var loginPrompt: LoginPrompt?

    var loginOrigin: String? { LoginOrigin.make(from: webView.url) }

    @ObservationIgnored private var observations: [NSKeyValueObservation] = []
    @ObservationIgnored private var pending: SessionTab?
    @ObservationIgnored var onTitleChange: ((URL, String) -> Void)?

    /// True for a restored tab whose page has not started loading yet.
    public var isAwaitingLoad: Bool { pending != nil }

    init(webView: WKWebView, state: TabLifecycleState, restoring session: SessionTab? = nil) {
        self.webView = webView
        self.state = state
        pending = session
        title = session?.title
        url = session?.url
        observations = [
            observe(\.title) { tab, webView in
                // A restored tab keeps its saved title until its page starts loading.
                guard !tab.isAwaitingLoad else { return }
                tab.title = webView.title.flatMap { $0.isEmpty ? nil : $0 }
                if !tab.isShowingError, let url = webView.url, let title = tab.title { tab.onTitleChange?(url, title) }
            },
            observe(\.url) { tab, webView in
                if !tab.isAwaitingLoad { tab.url = webView.url }
            },
            observe(\.isLoading) { $0.isLoading = $1.isLoading },
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
        if let state = pending.interactionState {
            webView.interactionState = state
        } else {
            webView.load(URLRequest(url: pending.url))
        }
    }

    func sessionTab(isSelected: Bool) -> SessionTab? {
        guard let url else { return nil }
        // WebKit documents the value as opaque; a test pins that it is Data on the supported macOS.
        let state = pending?.interactionState ?? webView.interactionState as? Data
        return SessionTab(url: url, title: title, isSelected: isSelected, interactionState: state)
    }
}
