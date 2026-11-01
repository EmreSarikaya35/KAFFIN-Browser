import AppKit
import BrowserCore

/// Theme switching only changes NSApp.appearance, so active WebViews are never recreated.
@MainActor
final class AppearanceController: NSObject, NSMenuItemValidation {
    static let shared = AppearanceController()

    func applySavedMode() {
        NSApp.appearance = BrowserPreferences.shared.theme.appearance
    }

    @objc func selectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let theme = AppTheme(rawValue: raw) else { return }
        BrowserPreferences.shared.theme = theme
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.state = menuItem.representedObject as? String == BrowserPreferences.shared.theme.rawValue ? .on : .off
        return true
    }
}
