import AppKit

/// Theme switching only changes NSApp.appearance, so active WebViews are never recreated.
@MainActor
final class AppearanceController: NSObject, NSMenuItemValidation {
    static let shared = AppearanceController()

    enum Mode: String, CaseIterable {
        case system, light, dark

        var titleKey: String { "appearance.\(rawValue)" }

        var appearance: NSAppearance? {
            switch self {
            case .system: nil
            case .light: NSAppearance(named: .aqua)
            case .dark: NSAppearance(named: .darkAqua)
            }
        }
    }

    private static let defaultsKey = "appearanceMode"

    private var mode: Mode {
        Mode(rawValue: UserDefaults.standard.string(forKey: Self.defaultsKey) ?? "") ?? .system
    }

    func applySavedMode() {
        NSApp.appearance = mode.appearance
    }

    @objc func selectMode(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let mode = Mode(rawValue: raw) else { return }
        UserDefaults.standard.set(mode.rawValue, forKey: Self.defaultsKey)
        NSApp.appearance = mode.appearance
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        menuItem.state = menuItem.representedObject as? String == mode.rawValue ? .on : .off
        return true
    }
}
