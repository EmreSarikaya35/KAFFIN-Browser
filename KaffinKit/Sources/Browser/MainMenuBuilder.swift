import AppKit
import BrowserCore

/// Items with a nil target travel the responder chain, so they reach the focused window's controller.
@MainActor
enum MainMenuBuilder {
    static func build(windowManager: WindowManager) -> NSMenu {
        let newWindow = item("window.new", #selector(WindowManager.newWindow(_:)), "n")
        newWindow.target = windowManager

        let mainMenu = NSMenu()
        for menu in [
            menu("KAFFIN", [
                item("menu.about", #selector(NSApplication.orderFrontStandardAboutPanel(_:)), ""),
                .separator(),
                item("menu.hide", #selector(NSApplication.hide(_:)), "h"),
                item("menu.quit", #selector(NSApplication.terminate(_:)), "q"),
            ]),
            menu(L10n.string("menu.file"), [
                item("tab.new", #selector(BrowserWindowController.newTab(_:)), "t"),
                newWindow,
                item("menu.focusAddress", #selector(BrowserWindowController.focusAddress(_:)), "l"),
                .separator(),
                item("tab.close", #selector(BrowserWindowController.closeTab(_:)), "w"),
            ]),
            menu(L10n.string("menu.edit"), [
                item("menu.undo", Selector(("undo:")), "z"),
                item("menu.redo", Selector(("redo:")), "Z"),
                .separator(),
                item("menu.cut", #selector(NSText.cut(_:)), "x"),
                item("menu.copy", #selector(NSText.copy(_:)), "c"),
                item("menu.paste", #selector(NSText.paste(_:)), "v"),
                item("menu.selectAll", #selector(NSText.selectAll(_:)), "a"),
            ]),
            menu(L10n.string("menu.view"), [
                item("nav.reload", #selector(BrowserWindowController.reloadPage(_:)), "r"),
                item("nav.back", #selector(BrowserWindowController.goBack(_:)), "["),
                item("nav.forward", #selector(BrowserWindowController.goForward(_:)), "]"),
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
        ])
        NSApp.windowsMenu = menu
        return menu
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
