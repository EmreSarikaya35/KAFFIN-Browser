import BrowserCore
import WebKit

/// Talks to the login script. The script and this handler exist only in an isolated world,
/// so page scripts can neither see the bridge nor send it messages.
@MainActor
final class LoginBridge: NSObject, WKScriptMessageHandler {
    static let world = WKContentWorld.world(name: "KaffinLogin")
    private static let handlerName = "kaffinLogin"

    // shortcut: only real form submissions are noticed; sites that log in with a plain button click offer no save.
    private static let script = """
    (() => {
      const post = (message) => webkit.messageHandlers.\(handlerName).postMessage(message);
      const selector = 'input[type="password"]';
      const usernameFor = (password) => {
        const fields = (password.form ?? document).querySelectorAll('input:not([type]),input[type="text"],input[type="email"]');
        return [...fields].filter((field) => field.compareDocumentPosition(password) & Node.DOCUMENT_POSITION_FOLLOWING).at(-1);
      };
      if (document.querySelector(selector)) post({ kind: 'form' });
      document.addEventListener('focusin', (event) => {
        if (event.target.matches?.(selector)) post({ kind: 'form' });
      }, true);
      document.addEventListener('submit', (event) => {
        const password = event.target.querySelector(selector);
        if (password?.value) post({ kind: 'submit', username: usernameFor(password)?.value ?? '', password: password.value });
      }, true);
    })();
    """

    /// Uses the prototype's setter, because frameworks like React ignore plain value assignment.
    static let fillScript = """
    const password = document.querySelector('input[type="password"]');
    if (!password) return;
    const fields = (password.form ?? document).querySelectorAll('input:not([type]),input[type="text"],input[type="email"]');
    const user = [...fields].filter((field) => field.compareDocumentPosition(password) & Node.DOCUMENT_POSITION_FOLLOWING).at(-1);
    const set = (field, value) => {
      Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, 'value').set.call(field, value);
      field.dispatchEvent(new Event('input', { bubbles: true }));
      field.dispatchEvent(new Event('change', { bubbles: true }));
    };
    if (user) set(user, username);
    set(password, secret);
    """

    /// Weak, because WebKit keeps this handler alive for as long as the page's controller exists.
    private weak var tabManager: TabManager?

    init(tabManager: TabManager) {
        self.tabManager = tabManager
    }

    func install(on controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(
            source: Self.script,
            injectionTime: .atDocumentEnd,
            forMainFrameOnly: true,
            in: Self.world
        ))
        controller.add(self, contentWorld: Self.world, name: Self.handlerName)
    }

    /// The script already runs in the moved page, so only its messages change owner.
    func takeOver(_ controller: WKUserContentController) {
        controller.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: Self.world)
        controller.add(self, contentWorld: Self.world, name: Self.handlerName)
    }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              let tabManager,
              let webView = message.webView,
              let tab = tabManager.tab(for: webView),
              let origin = tab.loginOrigin,
              origin == Self.origin(of: message.frameInfo.securityOrigin),
              let body = message.body as? [String: Any] else { return }

        switch body["kind"] as? String {
        case "form":
            Task { await tabManager.offerSavedLogins(on: tab, origin: origin) }
        case "submit":
            guard let password = body["password"] as? String, !password.isEmpty else { return }
            let login = SavedLogin(origin: origin, username: body["username"] as? String ?? "")
            Task { await tabManager.offerToSave(login, password: password, on: tab) }
        default:
            break
        }
    }

    private static func origin(of origin: WKSecurityOrigin) -> String {
        let base = "\(origin.protocol)://\(origin.host)"
        return origin.port == 0 ? base : "\(base):\(origin.port)"
    }
}
