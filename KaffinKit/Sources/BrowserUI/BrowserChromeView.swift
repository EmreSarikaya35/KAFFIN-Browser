import AppKit
import BrowserCore
import SwiftUI
import Tabs

/// Tab strip and toolbar, laid out after Chrome: the active tab merges into the toolbar below it.
public struct BrowserChromeView: View {
    public static let height: CGFloat = 84

    let tabManager: TabManager
    let focusRequest: Int
    let onSubmit: (String) -> Void

    public init(tabManager: TabManager, focusRequest: Int, onSubmit: @escaping (String) -> Void) {
        self.tabManager = tabManager
        self.focusRequest = focusRequest
        self.onSubmit = onSubmit
    }

    public var body: some View {
        VStack(spacing: 0) {
            tabStrip
            toolbar
            Divider()
        }
        .frame(height: Self.height)
    }

    private var tabStrip: some View {
        HStack(alignment: .bottom, spacing: 0) {
            ForEach(tabManager.tabs) { tab in
                TabItemView(tab: tab, tabManager: tabManager)
            }
            Button {
                tabManager.newTab()
            } label: {
                Image(systemName: "plus").frame(width: 28, height: 28)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(L10n.string("tab.new"))
            .padding(.leading, 4)
            .padding(.bottom, 3)
            Spacer(minLength: 40)
        }
        // Leaves room for the traffic-light buttons.
        .padding(.leading, 80)
        .frame(height: 40)
        .background(ChromePalette.strip)
        .gesture(WindowDragGesture())
    }

    private var toolbar: some View {
        let tab = tabManager.selectedTab
        return HStack(spacing: 6) {
            toolbarButton("chevron.left", key: "nav.back", enabled: tab?.canGoBack == true) {
                tab?.webView.goBack()
            }
            toolbarButton("chevron.right", key: "nav.forward", enabled: tab?.canGoForward == true) {
                tab?.webView.goForward()
            }
            if tab?.isLoading == true {
                toolbarButton("xmark", key: "nav.stop", enabled: true) { tab?.webView.stopLoading() }
            } else {
                toolbarButton("arrow.clockwise", key: "nav.reload", enabled: tab != nil) { tab?.webView.reload() }
            }
            addressBar(for: tab)
            mainMenu
        }
        .padding(.horizontal, 10)
        .frame(height: 43)
        .background(ChromePalette.toolbar)
    }

    private func addressBar(for tab: Tabs.Tab?) -> some View {
        HStack(spacing: 8) {
            SecurityIndicator(security: AddressDisplay.security(of: tab?.url))
            AddressField(
                text: AddressDisplay.text(for: tab?.url),
                placeholder: L10n.string("address.placeholder"),
                focusRequest: focusRequest,
                onSubmit: onSubmit
            )
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
        .glassEffect(in: Capsule())
    }

    private var mainMenu: some View {
        Menu {
            menuButton("tab.new", "newTab:")
            menuButton("window.new", "newWindow:")
            Divider()
            menuButton("zoom.in", "zoomIn:")
            menuButton("zoom.out", "zoomOut:")
            menuButton("zoom.reset", "resetZoom:")
        } label: {
            Image(systemName: "ellipsis").rotationEffect(.degrees(90))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(L10n.string("chrome.menu"))
    }

    /// Routes through the responder chain to the window controller, like the menu bar.
    private func menuButton(_ key: String, _ action: String) -> some View {
        Button(L10n.string(key)) {
            NSApp.sendAction(Selector(action), to: nil, from: nil)
        }
    }

    private func toolbarButton(
        _ symbol: String,
        key: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 28, height: 28)
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .accessibilityLabel(L10n.string(key))
    }
}

private struct SecurityIndicator: View {
    let security: ConnectionSecurity

    var body: some View {
        switch security {
        case .secure:
            Image(systemName: "lock.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .accessibilityLabel(L10n.string("security.secure"))
        case .notSecure:
            Label(L10n.string("security.notSecure"), systemImage: "exclamationmark.triangle.fill")
                .labelStyle(.titleAndIcon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize()
        case .none:
            EmptyView()
        }
    }
}

private struct TabItemView: View {
    let tab: Tabs.Tab
    let tabManager: TabManager

    private var isSelected: Bool { tab.id == tabManager.selectedTabID }

    var body: some View {
        HStack(spacing: 8) {
            if tab.isLoading {
                ProgressView().controlSize(.mini)
            } else {
                Image(systemName: "globe").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Text(tab.title ?? tab.url?.host() ?? L10n.string("tab.new"))
                .lineLimit(1)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                tabManager.close(tab.id)
            } label: {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).frame(width: 16, height: 16)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(L10n.string("tab.close"))
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 44, maxWidth: 240)
        .frame(height: 34)
        .background(
            isSelected ? ChromePalette.toolbar : .clear,
            in: UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8)
        )
        .contentShape(Rectangle())
        .onTapGesture { tabManager.select(tab.id) }
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .draggable(tab.id.uuidString)
        .dropDestination(for: String.self) { items, _ in
            guard let id = items.first.flatMap(UUID.init(uuidString:)) else { return false }
            tabManager.move(id, before: tab.id)
            return true
        }
        .contextMenu {
            Button(L10n.string("tab.new")) { tabManager.newTab() }
            Button(L10n.string("tab.reload")) { tab.webView.reload() }
            Button(L10n.string("tab.duplicate")) { tabManager.duplicate(tab.id) }
                .disabled(tab.url == nil)
            Divider()
            Button(L10n.string("tab.close")) { tabManager.close(tab.id) }
            Button(L10n.string("tab.closeOthers")) { tabManager.closeOthers(than: tab.id) }
                .disabled(tabManager.tabs.count < 2)
        }
    }
}
