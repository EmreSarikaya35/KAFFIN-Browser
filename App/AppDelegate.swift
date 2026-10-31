import AppKit
import Browser

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let windowManager = WindowManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        windowManager.start()
        NSApp.activate()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { windowManager.openWindow() }
        return true
    }
}
