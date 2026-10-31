import AppKit
import Browser

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let windowManager = WindowManager()

    func applicationDidFinishLaunching(_ notification: Notification) {
        windowManager.start()
        NSApp.activate()
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        windowManager.openURLs(urls)
    }

    func applicationWillTerminate(_ notification: Notification) {
        windowManager.saveSessionNow()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { windowManager.openWindow() }
        return true
    }
}
