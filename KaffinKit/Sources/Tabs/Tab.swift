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

    @ObservationIgnored private var observations: [NSKeyValueObservation] = []

    init(webView: WKWebView, state: TabLifecycleState) {
        self.webView = webView
        self.state = state
        observations = [
            observe(\.title) { $0.title = $1.title.flatMap { $0.isEmpty ? nil : $0 } },
            observe(\.url) { $0.url = $1.url },
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
        webView.load(URLRequest(url: url))
    }
}
