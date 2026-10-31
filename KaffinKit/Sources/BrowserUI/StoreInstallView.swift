import BrowserCore
import SwiftUI
import Tabs

/// The store's own Add button works only in Chrome, so this one appears over its extension pages.
public struct StoreInstallView: View {
    let tabManager: TabManager
    let extensions: ExtensionsModel

    @State private var isInstalling = false
    @State private var failedID: String?

    public init(tabManager: TabManager, extensions: ExtensionsModel) {
        self.tabManager = tabManager
        self.extensions = extensions
    }

    /// The listing on screen, unless it is already installed.
    public static func offer(tabManager: TabManager, extensions: ExtensionsModel) -> String? {
        ChromeWebStore.listingID(of: tabManager.selectedTab?.url).flatMap {
            extensions.isInstalled(storeID: $0) ? nil : $0
        }
    }

    public var body: some View {
        if let id = Self.offer(tabManager: tabManager, extensions: extensions) {
            HStack(spacing: 10) {
                if failedID == id {
                    Text(L10n.string("extensions.installFailed"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 300)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if isInstalling {
                    ProgressView().controlSize(.small)
                }
                // No keyboard shortcut: Return belongs to the page, and must never start an install.
                Button(L10n.string("extensions.addToKaffin")) { install(id) }
                    .controlSize(.large)
                    .disabled(isInstalling)
            }
            .padding(10)
            .background(ChromePalette.toolbar, in: RoundedRectangle(cornerRadius: 8))
            .shadow(radius: 4, y: 1)
            .padding(4)
        }
    }

    private func install(_ id: String) {
        failedID = nil
        isInstalling = true
        Task {
            do {
                try await extensions.commands?.installFromStore(id: id)
            } catch {
                // Declining the permissions is a choice, not a failure.
                if error as? ExtensionInstallError != .declined { failedID = id }
            }
            isInstalling = false
        }
    }
}
