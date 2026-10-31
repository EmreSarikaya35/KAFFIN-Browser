import AppKit
import BrowserCore

/// Items with a nil target travel the responder chain, so they reach the focused window's controller.
@MainActor
enum MainMenuBuilder {
    static func build(windowManager: WindowManager) -> NSMenu {
        let newWindow = item("window.new", #selector(WindowManager.newWindow(_:)), "n")
        newWindow.target = windowManager
        let newPrivateWindow = item("window.newPrivate", #selector(WindowManager.newPrivateWindow(_:)), "N")
        newPrivateWindow.target = windowManager
        let showHistory = item("history.show", #selector(WindowManager.showHistory(_:)), "y")
        showHistory.target = windowManager

        let setDefault = item("menu.setDefault", #selector(WindowManager.setAsDefaultBrowser(_:)), "")
        setDefault.target = windowManager

        let settings = item("menu.settings", #selector(WindowManager.showSettings(_:)), ",")
        settings.target = windowManager

        let mainMenu = NSMenu()
        for menu in [
            menu("KAFFIN", [
                item("menu.about", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
                .separator(),
                settings,
                setDefault,
                .separator(),
                item("menu.hide", #selector(NSApplication.hide(_:)), "h"),
                item("menu.quit", #selector(NSApplication.terminate(_:)), "q"),
            ]),
            menu(L10n.string("menu.file"), [
                item("tab.new", #selector(BrowserWindowController.newTab(_:)), "t"),
                newWindow,
                newPrivateWindow,
                item("tab.reopen", #selector(BrowserWindowController.reopenClosedTab(_:)), "T"),
                item("menu.focusAddress", #selector(BrowserWindowController.focusAddress(_:)), "l"),
                .separator(),
                item("tab.close", #selector(BrowserWindowController.closeTab(_:)), "w"),
                .separator(),
                item("menu.print", #selector(BrowserWindowController.printPage(_:)), "p"),
            ]),
            menu(L10n.string("menu.edit"), [
                item("menu.undo", Selector(("undo:")), "z"),
                item("menu.redo", Selector(("redo:")), "Z"),
                .separator(),
                item("menu.cut", #selector(NSText.cut(_:)), "x"),
                item("menu.copy", #selector(NSText.copy(_:)), "c"),
                item("menu.paste", #selector(NSText.paste(_:)), "v"),
                item("menu.selectAll", #selector(NSText.selectAll(_:)), "a"),
                .separator(),
                item("find.show", #selector(BrowserWindowController.showFind(_:)), "f"),
            ]),
            menu(L10n.string("menu.view"), [
                item("nav.reload", #selector(BrowserWindowController.reloadPage(_:)), "r"),
                item("nav.back", #selector(BrowserWindowController.goBack(_:)), "["),
                item("nav.forward", #selector(BrowserWindowController.goForward(_:)), "]"),
                .separator(),
                item("zoom.in", #selector(BrowserWindowController.zoomIn(_:)), "+"),
                item("zoom.out", #selector(BrowserWindowController.zoomOut(_:)), "-"),
                item("zoom.reset", #selector(BrowserWindowController.resetZoom(_:)), "0"),
                .separator(),
                appearanceItem(),
            ]),
            menu(L10n.string("menu.history"), [showHistory]),
            menu(L10n.string("menu.bookmarks"), [
                item("bookmark.add", #selector(BrowserWindowController.toggleBookmark(_:)), "d"),
                item("bookmark.toggleBar", #selector(BrowserWindowController.toggleBookmarksBar(_:)), "B"),
            ]),
            windowMenu(),
        ] {
            let holder = NSMenuItem()
            holder.submenu = menu
            mainMenu.addItem(holder)
        }
        return mainMenu
    }

    private static func windowMenu() -> NSMenu {
        let menu = menu(L10n.string("menu.window"), [
            item("menu.minimize", #selector(NSWindow.miniaturize(_:)), "m"),
            .separator(),
            item("menu.nextTab", #selector(BrowserWindowController.selectNextTab(_:)), "}"),
            item("menu.previousTab", #selector(BrowserWindowController.selectPreviousTab(_:)), "{"),
        ] + (1...9).map { number in
            let item = NSMenuItem(
                title: String(format: L10n.string("menu.tabNumber"), number),
                action: #selector(BrowserWindowController.selectNumberedTab(_:)),
                keyEquivalent: String(number)
            )
            item.tag = number - 1
            return item
        })
        NSApp.windowsMenu = menu
        return menu
    }

    private static func appearanceItem() -> NSMenuItem {
        let parent = NSMenuItem(title: L10n.string("appearance.title"), action: nil, keyEquivalent: "")
        parent.submenu = menu(L10n.string("appearance.title"), AppearanceController.Mode.allCases.map { mode in
            let item = NSMenuItem(
                title: L10n.string(mode.titleKey),
                action: #selector(AppearanceController.selectMode(_:)),
                keyEquivalent: ""
            )
            item.target = AppearanceController.shared
            item.representedObject = mode.rawValue
            return item
        })
        return parent
    }

    private static func menu(_ title: String, _ items: [NSMenuItem]) -> NSMenu {
        let menu = NSMenu(title: title)
        items.forEach(menu.addItem)
        return menu
    }

    private static func item(_ key: String, _ action: Selector, _ shortcut: String) -> NSMenuItem {
        NSMenuItem(title: L10n.string(key), action: action, keyEquivalent: shortcut)
    }
}
