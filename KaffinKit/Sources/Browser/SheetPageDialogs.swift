import AppKit
import BrowserCore
import Foundation
import Tabs

/// Shows a page's requests as sheets on its window. Each names the site, so a page cannot pose as the browser.
@MainActor
final class SheetPageDialogs: PageDialogPresenting {
    private weak var window: NSWindow?
    private let locationAccess: SystemLocationAccess

    init(window: NSWindow?, locationAccess: SystemLocationAccess) {
        self.window = window
        self.locationAccess = locationAccess
    }

    private func present(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        guard let window else { return .abort }
        return await alert.beginSheetModal(for: window)
    }

    private func makeAlert(_ title: String, detail: String = "", primary: String = L10n.string("dialog.ok")) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: primary)
        return alert
    }

    private func heading(for site: String) -> String {
        String(format: L10n.string("dialog.from"), site)
    }

    func alert(_ message: String, from site: String) async {
        _ = await present(makeAlert(heading(for: site), detail: message))
    }

    func confirm(_ message: String, from site: String) async -> Bool {
        let alert = makeAlert(heading(for: site), detail: message)
        alert.addButton(withTitle: L10n.string("dialog.cancel"))
        return await present(alert) == .alertFirstButtonReturn
    }

    func prompt(_ message: String, defaultText: String?, from site: String) async -> String? {
        let alert = makeAlert(heading(for: site), detail: message)
        alert.addButton(withTitle: L10n.string("dialog.cancel"))
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.stringValue = defaultText ?? ""
        alert.accessoryView = field
        alert.window.initialFirstResponder = field
        return await present(alert) == .alertFirstButtonReturn ? field.stringValue : nil
    }

    func credential(for site: String, realm: String?) async -> URLCredential? {
        let alert = makeAlert(
            String(format: L10n.string("dialog.signIn"), site),
            detail: realm ?? "",
            primary: L10n.string("dialog.signInButton")
        )
        alert.addButton(withTitle: L10n.string("dialog.cancel"))

        let user = NSTextField(frame: NSRect(x: 0, y: 30, width: 280, height: 24))
        user.placeholderString = L10n.string("dialog.username")
        let password = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        password.placeholderString = L10n.string("dialog.password")
        let fields = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 54))
        fields.addSubview(user)
        fields.addSubview(password)
        alert.accessoryView = fields
        alert.window.initialFirstResponder = user

        guard await present(alert) == .alertFirstButtonReturn else { return nil }
        return URLCredential(user: user.stringValue, password: password.stringValue, persistence: .forSession)
    }

    func askPermission(_ kind: SitePermissionKind, for site: String) async -> PermissionAnswer {
        let alert = makeAlert(
            String(format: L10n.string("permission.question"), site, L10n.string("permission.\(kind.rawValue)")),
            primary: L10n.string("permission.allow")
        )
        alert.addButton(withTitle: L10n.string("permission.block"))
        alert.addButton(withTitle: L10n.string("permission.notNow"))
        switch await present(alert) {
        case .alertFirstButtonReturn: return .allow
        case .alertSecondButtonReturn: return .block
        default: return .notNow
        }
    }

    /// Without this message a refused app-wide setting would look like a broken website.
    func ensureSystemLocationAccess() async -> Bool {
        if await locationAccess.requestAccess() { return true }
        let alert = makeAlert(
            L10n.string("permission.locationOff"),
            detail: L10n.string("permission.locationOffDetail"),
            primary: L10n.string("permission.openSettings")
        )
        alert.addButton(withTitle: L10n.string("dialog.cancel"))
        if await present(alert) == .alertFirstButtonReturn,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices") {
            NSWorkspace.shared.open(url)
        }
        return false
    }

    func confirmOpening(_ url: URL, from site: String) async -> Bool {
        let alert = makeAlert(
            L10n.string("dialog.openApp"),
            detail: String(format: L10n.string("dialog.openAppDetail"), site, url.absoluteString),
            primary: L10n.string("dialog.openAppButton")
        )
        alert.addButton(withTitle: L10n.string("dialog.cancel"))
        return await present(alert) == .alertFirstButtonReturn
    }
}
