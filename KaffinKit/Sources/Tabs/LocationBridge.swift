import CoreLocation
import WebKit

/// WebKit on macOS asks for location permission but never reads a location, so KAFFIN supplies it.
/// Page scripts must see the replaced API, but the native handler stays in an isolated world:
/// a handler in the page world would expose `window.webkit`, which marks KAFFIN as an embedded web view.
// shortcut: main frame only and ignores timeout, maximumAge and enableHighAccuracy, upgrade if a real site needs them.
@MainActor
final class LocationBridge: NSObject, WKScriptMessageHandlerWithReply {
    private static let world = WKContentWorld.world(name: "KaffinLocation")
    private static let handlerName = "kaffinLocation"
    private static let requestEvent = "kaffin-location-request"
    private static let replyEvent = "kaffin-location-reply"
    private static let watchInterval = 10_000

    private static let pageScript = """
    (() => {
      const failure = (code, message) => ({ code, message, PERMISSION_DENIED: 1, POSITION_UNAVAILABLE: 2, TIMEOUT: 3 });
      const pending = new Map();
      const watches = new Map();
      let nextID = 0;
      window.addEventListener('\(replyEvent)', (event) => {
        const reply = JSON.parse(event.detail);
        pending.get(reply.id)?.(reply);
        pending.delete(reply.id);
      });
      const locate = (success, fail) => {
        const id = ++nextID;
        pending.set(id, (reply) => {
          if (reply.error === 1) return fail?.(failure(1, 'User denied Geolocation'));
          if (reply.error) return fail?.(failure(2, 'Position unavailable'));
          const { latitude, longitude, accuracy, altitude = null, altitudeAccuracy = null, heading = null, speed = null, timestamp } = reply;
          success({ coords: { latitude, longitude, accuracy, altitude, altitudeAccuracy, heading, speed }, timestamp });
        });
        window.dispatchEvent(new CustomEvent('\(requestEvent)', { detail: id }));
      };
      const api = {
        getCurrentPosition(success, fail) { locate(success, fail); },
        watchPosition(success, fail) {
          const id = ++nextID;
          let isBusy = false;
          const stop = () => { clearInterval(watches.get(id)); watches.delete(id); };
          const tick = () => {
            if (isBusy || document.hidden) return;
            isBusy = true;
            locate((position) => {
              isBusy = false;
              if (watches.has(id)) success(position);
            }, (error) => {
              isBusy = false;
              if (error.code === 1) stop();
              fail?.(error);
            });
          };
          watches.set(id, setInterval(tick, \(watchInterval)));
          tick();
          return id;
        },
        clearWatch(id) { clearInterval(watches.get(id)); watches.delete(id); },
      };
      for (const [name, value] of Object.entries(api)) {
        Object.defineProperty(Geolocation.prototype, name, { value, writable: true, configurable: true });
      }
    })();
    """

    private static let isolatedScript = """
    window.addEventListener('\(requestEvent)', async (event) => {
      const reply = await webkit.messageHandlers.\(handlerName).postMessage({});
      window.dispatchEvent(new CustomEvent('\(replyEvent)', { detail: JSON.stringify({ ...reply, id: event.detail }) }));
    });
    """

    private weak var tabManager: TabManager?

    init(tabManager: TabManager) {
        self.tabManager = tabManager
    }

    func install(on controller: WKUserContentController) {
        controller.addUserScript(WKUserScript(source: Self.pageScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: .page))
        controller.addUserScript(WKUserScript(source: Self.isolatedScript, injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.world))
        controller.addScriptMessageHandler(self, contentWorld: Self.world, name: Self.handlerName)
    }

    /// The scripts already run in the moved page, so only its messages change owner.
    func takeOver(_ controller: WKUserContentController) {
        controller.removeScriptMessageHandler(forName: Self.handlerName, contentWorld: Self.world)
        controller.addScriptMessageHandler(self, contentWorld: Self.world, name: Self.handlerName)
    }

    /// The origin comes from WebKit, never from the page, because a page can fire the request event itself.
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) async -> (Any?, String?) {
        let origin = message.frameInfo.securityOrigin
        guard message.frameInfo.isMainFrame,
              Self.isSecure(scheme: origin.protocol, host: origin.host),
              let tabManager,
              await tabManager.decidePermission(.location, site: NavigationManager.site(of: origin)) else {
            return (["error": 1], nil)
        }
        guard let location = await tabManager.dialogs?.currentLocation() else { return (["error": 2], nil) }
        return (Self.reply(for: location), nil)
    }

    static func isSecure(scheme: String, host: String) -> Bool {
        scheme == "https" || host == "localhost" || host == "127.0.0.1"
    }

    /// CoreLocation marks unknown values as negative; leaving them out makes them null on the page.
    private static func reply(for location: CLLocation) -> [String: Any] {
        var reply: [String: Any] = [
            "latitude": location.coordinate.latitude,
            "longitude": location.coordinate.longitude,
            "accuracy": location.horizontalAccuracy,
            "timestamp": location.timestamp.timeIntervalSince1970 * 1000,
        ]
        if location.verticalAccuracy >= 0 {
            reply["altitude"] = location.altitude
            reply["altitudeAccuracy"] = location.verticalAccuracy
        }
        if location.course >= 0 { reply["heading"] = location.course }
        if location.speed >= 0 { reply["speed"] = location.speed }
        return reply
    }
}
