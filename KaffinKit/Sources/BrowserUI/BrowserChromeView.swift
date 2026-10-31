import AppKit
import BrowserCore
import SwiftUI
import Tabs

/// Nil on private windows, which belong to no switchable profile.
public struct ProfileMenu {
    let list: ProfileList
    let current: UUID
    let onOpen: (UUID) -> Void
    let onAdd: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    public init(
        list: ProfileList,
        current: UUID,
        onOpen: @escaping (UUID) -> Void,
        onAdd: @escaping () -> Void,
        onRename: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        self.list = list
        self.current = current
        self.onOpen = onOpen
        self.onAdd = onAdd
        self.onRename = onRename
        self.onDelete = onDelete
    }
}

/// Tab strip and toolbar, laid out after Chrome: the active tab merges into the toolbar below it.
public struct BrowserChromeView: View {
    public static let height: CGFloat = 84
    public static let bookmarksBarHeight: CGFloat = 32

    let tabManager: TabManager
    let bookmarks: BookmarksModel
    let downloads: DownloadManager
    let search: SearchSettings
    let accent: AccentSettings
    let suggestions: SuggestionsModel
    let profileMenu: ProfileMenu?
    let isPrivate: Bool
    let focusRequest: Int
    let onSubmit: (String) -> Void

    @State private var isShowingDownloads = false
    @Environment(\.controlActiveState) private var activeState

    public init(
        tabManager: TabManager,
        bookmarks: BookmarksModel,
        downloads: DownloadManager,
        search: SearchSettings,
        accent: AccentSettings,
        suggestions: SuggestionsModel,
        profileMenu: ProfileMenu?,
        isPrivate: Bool,
        focusRequest: Int,
        onSubmit: @escaping (String) -> Void
    ) {
        self.tabManager = tabManager
        self.bookmarks = bookmarks
        self.downloads = downloads
        self.search = search
        self.accent = accent
        self.suggestions = suggestions
        self.profileMenu = profileMenu
        self.isPrivate = isPrivate
        self.focusRequest = focusRequest
        self.onSubmit = onSubmit
    }

    public var body: some View {
        VStack(spacing: 0) {
            TabStripView(tabManager: tabManager, accent: accent.color?.swiftUIColor, isPrivate: isPrivate)
            toolbar
            if bookmarks.isBarVisible {
                BookmarksBarView(bookmarks: bookmarks) { tabManager.selectedTab?.load($0.url) }
            }
            Divider()
        }
        .tint(accent.color?.swiftUIColor)
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
            toolbarButton("arrow.down.circle", key: "downloads.title", enabled: true) {
                isShowingDownloads.toggle()
            }
            .popover(isPresented: $isShowingDownloads, arrowEdge: .bottom) {
                DownloadsView(downloads: downloads)
            }
            // Downloads are shared by all windows, so only the focused one reacts.
            .onChange(of: downloads.items.count) { old, new in
                if new > old, activeState == .key { isShowingDownloads = true }
            }
            if let profileMenu { ProfileButton(menu: profileMenu) }
            mainMenu
        }
        .padding(.horizontal, 10)
        .frame(height: 43)
        .background(ChromePalette.toolbar)
    }

    private func addressBar(for tab: Tabs.Tab?) -> some View {
        HStack(spacing: 8) {
            SecurityIndicator(security: tab?.isShowingError == true ? .notSecure : AddressDisplay.security(of: tab?.url))
            AddressField(
                text: AddressDisplay.text(for: tab?.url),
                placeholder: String(format: L10n.string("address.placeholder"), search.engine.name),
                focusRequest: focusRequest,
                onSubmit: onSubmit,
                inlineCompletion: suggestions.inlineCompletion,
                onEdit: { text, grew in
                    Task { await suggestions.update(text: text, engine: search.engine, allowsCompletion: grew) }
                },
                onMoveSelection: { suggestions.move(by: $0) },
                onEndEditing: {
                    // Leaves time for a click on a row, which may arrive after the field loses focus.
                    Task {
                        try? await Task.sleep(for: .milliseconds(150))
                        suggestions.clear()
                    }
                }
            )
            bookmarkButton(for: tab)
        }
        .padding(.horizontal, 14)
        .frame(height: 32)
        .glassEffect(in: Capsule())
    }

    private func bookmarkButton(for tab: Tabs.Tab?) -> some View {
        let isBookmarked = bookmarks.contains(tab?.url)
        return Button {
            guard let url = tab?.url else { return }
            Task { await bookmarks.toggle(url: url, title: tab?.title) }
        } label: {
            Image(systemName: isBookmarked ? "star.fill" : "star").font(.system(size: 13))
        }
        .buttonStyle(.borderless)
        .disabled(tab?.url == nil)
        .accessibilityLabel(L10n.string(isBookmarked ? "bookmark.remove" : "bookmark.add"))
    }

    private var mainMenu: some View {
        Menu {
            menuButton("tab.new", "newTab:")
            menuButton("window.new", "newWindow:")
            menuButton("window.newPrivate", "newPrivateWindow:")
            Divider()
            menuButton("history.show", "showHistory:")
            menuButton("menu.passwords", "showPasswords:")
            menuButton("menu.settings", "showSettings:")
            Divider()
            menuButton("zoom.in", "zoomIn:")
            menuButton("zoom.out", "zoomOut:")
            menuButton("zoom.reset", "resetZoom:")
            Divider()
            menuButton("find.show", "showFind:")
            menuButton("menu.print", "printPage:")
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

private struct ProfileButton: View {
    let menu: ProfileMenu

    private var current: Profile? { menu.list.profiles.first { $0.id == menu.current } }

    var body: some View {
        Menu {
            ForEach(menu.list.profiles) { profile in
                Button {
                    menu.onOpen(profile.id)
                } label: {
                    if profile.id == menu.current {
                        Label(profile.name, systemImage: "checkmark")
                    } else {
                        Text(profile.name)
                    }
                }
            }
            Divider()
            Button(L10n.string("profile.add"), action: menu.onAdd)
            Button(L10n.string("profile.rename"), action: menu.onRename)
            Button(L10n.string("profile.delete"), role: .destructive, action: menu.onDelete)
                .disabled(menu.current == WebViewFactory.defaultProfileID)
        } label: {
            Text(String(current?.name.prefix(1) ?? "").uppercased())
                .font(.system(size: 12, weight: .semibold))
                .frame(width: 22, height: 22)
                .background(ChromePalette.field, in: Circle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel(String(format: L10n.string("profile.menu"), current?.name ?? ""))
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

private struct TabDrag {
    let id: Tabs.Tab.ID
    let startIndex: Int
    var translation: CGFloat
    var tabWidth: CGFloat
}

private struct TabStripView: View {
    let tabManager: TabManager
    let accent: Color?
    let isPrivate: Bool

    @State private var drag: TabDrag?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var animation: Animation? { reduceMotion ? nil : .easeOut(duration: 0.12) }

    var body: some View {
        HStack(alignment: .bottom, spacing: 0) {
            ForEach(Array(tabManager.tabs.enumerated()), id: \.element.id) { index, tab in
                TabItemView(
                    tab: tab,
                    tabManager: tabManager,
                    accent: accent,
                    dragOffset: dragOffset(of: tab, at: index),
                    isDragging: drag?.id == tab.id,
                    onDragChanged: { updateDrag(of: tab, translation: $0, tabWidth: $1) },
                    onDragEnded: { withAnimation(animation) { drag = nil } }
                )
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
            if isPrivate {
                Label(L10n.string("window.private"), systemImage: "eye.slash")
                    .font(.system(size: 12, weight: .medium))
                    .padding(.trailing, 12)
                    .padding(.bottom, 10)
            }
        }
        // Leaves room for the traffic-light buttons.
        .padding(.leading, 80)
        .frame(height: 40)
        .background(ChromePalette.strip)
        .gesture(WindowDragGesture())
    }

    private func dragOffset(of tab: Tabs.Tab, at index: Int) -> CGFloat {
        guard let drag, drag.id == tab.id else { return 0 }
        return TabDragLayout.offset(
            start: drag.startIndex,
            current: index,
            range: tabManager.moveRange(of: tab),
            translation: drag.translation,
            tabWidth: drag.tabWidth
        )
    }

    private func updateDrag(of tab: Tabs.Tab, translation: CGFloat, tabWidth: CGFloat) {
        guard let current = tabManager.tabs.firstIndex(where: { $0.id == tab.id }) else { return }
        if drag?.id != tab.id {
            tabManager.select(tab.id)
            drag = TabDrag(id: tab.id, startIndex: current, translation: 0, tabWidth: tabWidth)
        }
        drag?.translation = translation
        guard let drag else { return }
        let target = TabDragLayout.targetIndex(
            start: drag.startIndex,
            range: tabManager.moveRange(of: tab),
            translation: translation,
            tabWidth: drag.tabWidth
        )
        if target != current {
            withAnimation(animation) { tabManager.move(tab.id, to: target) }
        }
    }
}

private struct TabItemView: View {
    let tab: Tabs.Tab
    let tabManager: TabManager
    let accent: Color?
    let dragOffset: CGFloat
    let isDragging: Bool
    let onDragChanged: (CGFloat, CGFloat) -> Void
    let onDragEnded: () -> Void

    @State private var width: CGFloat = 0

    private var isSelected: Bool { tab.id == tabManager.selectedTabID }
    private var title: String { tab.title ?? tab.url?.host() ?? L10n.string("tab.new") }

    var body: some View {
        HStack(spacing: 8) {
            if tab.isLoading {
                ProgressView().controlSize(.mini)
            } else if let image = tab.favicon.flatMap(NSImage.init(data:)) {
                Image(nsImage: image).resizable().frame(width: 16, height: 16)
            } else {
                Image(systemName: "globe").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if !tab.isPinned {
                Text(title)
                    .lineLimit(1)
                    .font(.system(size: 12))
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if tab.isMuted {
                Button {
                    Task { await tabManager.toggleMute(tab.id) }
                } label: {
                    Image(systemName: "speaker.slash.fill").font(.system(size: 10))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L10n.string("tab.unmute"))
            }
            if !tab.isPinned {
                Button {
                    tabManager.close(tab.id)
                } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .semibold)).frame(width: 16, height: 16)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(L10n.string("tab.close"))
            }
        }
        .padding(.horizontal, 10)
        .frame(minWidth: 44, maxWidth: tab.isPinned ? 44 : 240)
        .fixedSize(horizontal: tab.isPinned, vertical: false)
        .frame(height: 34)
        .accessibilityLabel(title)
        .background(
            isSelected ? ChromePalette.toolbar : .clear,
            in: UnevenRoundedRectangle(topLeadingRadius: 8, topTrailingRadius: 8)
        )
        .overlay(alignment: .top) {
            if isSelected, let accent {
                accent.frame(height: 2).padding(.horizontal, 8)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { tabManager.select(tab.id) }
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .onGeometryChange(for: CGFloat.self, of: \.size.width) { width = $0 }
        .offset(x: dragOffset)
        .zIndex(isDragging ? 1 : 0)
        // The dragged tab follows the pointer exactly; only its neighbors animate.
        .transaction { if isDragging { $0.animation = nil } }
        // Global space, because the tab itself moves under the pointer during the drag.
        .gesture(
            DragGesture(minimumDistance: 4, coordinateSpace: .global)
                .onChanged { onDragChanged($0.translation.width, width) }
                .onEnded { _ in onDragEnded() }
        )
        .contextMenu {
            Button(L10n.string("tab.new")) { tabManager.newTab() }
            Button(L10n.string("tab.reload")) { tab.webView.reload() }
            Button(L10n.string("tab.duplicate")) { tabManager.duplicate(tab.id) }
                .disabled(tab.url == nil)
            Button(L10n.string("tab.moveToNewWindow")) { tabManager.onMoveToNewWindow?(tab.id) }
                .disabled(tabManager.tabs.count < 2)
            Button(L10n.string(tab.isPinned ? "tab.unpin" : "tab.pin")) { tabManager.togglePin(tab.id) }
            Button(L10n.string(tab.isMuted ? "tab.unmute" : "tab.mute")) {
                Task { await tabManager.toggleMute(tab.id) }
            }
            Divider()
            Button(L10n.string("tab.close")) { tabManager.close(tab.id) }
            Button(L10n.string("tab.closeOthers")) { tabManager.closeOthers(than: tab.id) }
                .disabled(tabManager.tabs.count < 2)
        }
    }
}
