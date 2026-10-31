import AppKit
import BrowserCore

/// Entry point for the app target: owns the browser windows and the menu bar.
@MainActor
public final class WindowManager: NSObject {
    private let factory = WebViewFactory()
    private var controllers: [BrowserWindowController] = []

    public func start() {
        NSApp.mainMenu = MainMenuBuilder.build(windowManager: self)
        openWindow()
    }

    public func openWindow() {
        let controller = BrowserWindowController(factory: factory)
        controller.onClose = { [weak self] closed in
            self?.controllers.removeAll { $0 === closed }
        }
        controllers.append(controller)
        controller.showWindow(nil)
    }

    @objc func newWindow(_ sender: Any?) {
        openWindow()
    }
}
