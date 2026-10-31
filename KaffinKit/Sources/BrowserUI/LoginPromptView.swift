import BrowserCore
import SwiftUI
import Tabs

/// Saving or filling a password always takes an explicit click here.
public struct LoginPromptView: View {
    let tabManager: TabManager

    public init(tabManager: TabManager) {
        self.tabManager = tabManager
    }

    public var body: some View {
        if let tab = tabManager.selectedTab, let prompt = tab.loginPrompt {
            VStack(alignment: .leading, spacing: 10) {
                switch prompt {
                case .save(let login, _, let isUpdate):
                    Text(L10n.string(isUpdate ? "password.updateTitle" : "password.saveTitle")).font(.headline)
                    Text(Self.description(of: login)).foregroundStyle(.secondary).lineLimit(1)
                    HStack {
                        Spacer()
                        Button(L10n.string("password.notNow")) { tabManager.dismissLoginPrompt(on: tab) }
                        // No keyboard shortcut: Return belongs to the page, and must never save a password.
                        Button(L10n.string(isUpdate ? "password.update" : "password.save")) {
                            Task { await tabManager.acceptLoginPrompt(on: tab) }
                        }
                    }
                case .fill(let logins):
                    Text(L10n.string("password.fillTitle")).font(.headline)
                    ForEach(logins) { login in
                        Button(login.username.isEmpty ? login.origin : login.username) {
                            Task { await tabManager.fill(login, on: tab) }
                        }
                    }
                    HStack {
                        Spacer()
                        Button(L10n.string("password.notNow")) { tabManager.dismissLoginPrompt(on: tab) }
                    }
                }
            }
            .padding(14)
            .frame(width: 300, alignment: .leading)
            .background(ChromePalette.toolbar, in: RoundedRectangle(cornerRadius: 8))
            .shadow(radius: 4, y: 1)
            .padding(4)
        }
    }

    static func description(of login: SavedLogin) -> String {
        login.username.isEmpty ? login.origin : "\(login.username) · \(login.origin)"
    }
}
