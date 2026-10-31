import BrowserCore
import SwiftUI
import Tabs

/// Tab strip and toolbar. Phase 1 keeps this functional; Chrome-accurate styling is Phase 2.
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
        .background(.bar)
    }

    private var tabStrip: some View {
        HStack(spacing: 4) {
            ForEach(tabManager.tabs) { tab in
                TabItemView(
                    tab: tab,
                    isSelected: tab.id == tabManager.selectedTabID,
                    onSelect: { tabManager.select(tab.id) },
                    onClose: { tabManager.close(tab.id) }
                )
            }
            Button {
                tabManager.newTab()
            } label: {
                Image(systemName: "plus")
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(L10n.string("tab.new"))
            Spacer(minLength: 0)
        }
        // Leaves room for the traffic-light buttons.
        .padding(.leading, 80)
        .padding(.trailing, 8)
        .frame(height: 40)
        .gesture(WindowDragGesture())
    }

    private var toolbar: some View {
        let tab = tabManager.selectedTab
        return HStack(spacing: 8) {
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
            AddressField(
                text: tab?.url?.absoluteString ?? "",
                placeholder: L10n.string("address.placeholder"),
                focusRequest: focusRequest,
                onSubmit: onSubmit
            )
            .padding(.horizontal, 12)
            .frame(height: 30)
            .background(Color(nsColor: .textBackgroundColor), in: Capsule())
        }
        .padding(.horizontal, 10)
        .frame(height: 43)
    }

    private func toolbarButton(
        _ symbol: String,
        key: String,
        enabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 24, height: 24)
        }
        .buttonStyle(.borderless)
        .disabled(!enabled)
        .accessibilityLabel(L10n.string(key))
    }
}

private struct TabItemView: View {
    let tab: Tabs.Tab
    let isSelected: Bool
    let onSelect: () -> Void
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Text(tab.title ?? tab.url?.host() ?? L10n.string("tab.new"))
                .lineLimit(1)
                .font(.system(size: 12))
                .frame(maxWidth: .infinity, alignment: .leading)
            Button(action: onClose) {
                Image(systemName: "xmark").font(.system(size: 9, weight: .semibold))
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(L10n.string("tab.close"))
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 60, maxWidth: 220, minHeight: 32)
        .background(isSelected ? Color(nsColor: .textBackgroundColor) : .clear, in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture(perform: onSelect)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
