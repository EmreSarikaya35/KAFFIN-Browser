import AppKit
import BrowserCore
import SwiftUI

struct BookmarksBarView: View {
    let bookmarks: BookmarksModel
    let onOpen: (BookmarkItem) -> Void

    private enum Entry: Identifiable {
        case folder(BookmarkTree)
        case item(BookmarkItem)

        var id: String {
            switch self {
            case .folder(let folder): "folder-\(folder.id ?? 0)"
            case .item(let item): item.url.absoluteString
            }
        }

        var title: String {
            switch self {
            case .folder(let folder): folder.title
            case .item(let item): item.title
            }
        }
    }

    private static let font = NSFont.systemFont(ofSize: 12)
    private static let maximumTitleWidth: CGFloat = 160
    private static let overflowWidth: CGFloat = 34

    private var entries: [Entry] {
        bookmarks.tree.folders.map(Entry.folder) + bookmarks.tree.items.map(Entry.item)
    }

    /// Measured here because the bar must decide what fits before SwiftUI lays it out.
    private func width(of entry: Entry) -> CGFloat {
        let text = (entry.title as NSString).size(withAttributes: [.font: Self.font]).width
        var width = min(text, Self.maximumTitleWidth) + 16
        if case .folder = entry { width += 22 }
        return width
    }

    var body: some View {
        GeometryReader { proxy in
            let entries = entries
            let visible = BookmarkBarFit.visibleCount(
                widths: entries.map(width),
                available: proxy.size.width,
                overflowWidth: Self.overflowWidth
            )
            HStack(spacing: 0) {
                if entries.isEmpty {
                    Text(L10n.string("bookmark.empty"))
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 6)
                }
                ForEach(entries.prefix(visible)) { entry in
                    view(for: entry)
                }
                Spacer(minLength: 0)
                if visible < entries.count {
                    Menu {
                        ForEach(entries.dropFirst(visible)) { menuContent(for: $0) }
                    } label: {
                        Image(systemName: "chevron.right.2").font(.system(size: 11))
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .accessibilityLabel(L10n.string("bookmark.more"))
                }
            }
            .frame(height: proxy.size.height)
            .contentShape(Rectangle())
            .contextMenu { newFolderButton(parent: nil) }
        }
        .padding(.horizontal, 8)
        .frame(height: BrowserChromeView.bookmarksBarHeight)
        .background(ChromePalette.toolbar)
    }

    @ViewBuilder
    private func view(for entry: Entry) -> some View {
        switch entry {
        case .folder(let folder):
            Menu {
                folderContent(folder)
            } label: {
                Label(folder.title, systemImage: "folder").font(.system(size: 12)).lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(maxWidth: Self.maximumTitleWidth + 22)
            .fixedSize()
            .padding(.horizontal, 6)
        case .item(let item):
            Button {
                onOpen(item)
            } label: {
                Text(item.title).font(.system(size: 12)).lineLimit(1).frame(maxWidth: Self.maximumTitleWidth)
            }
            .buttonStyle(.borderless)
            .padding(.horizontal, 8)
            .contextMenu {
                moveMenu(for: item)
                Button(L10n.string("bookmark.remove")) {
                    Task { await bookmarks.remove(item) }
                }
            }
        }
    }

    @ViewBuilder
    private func menuContent(for entry: Entry) -> some View {
        switch entry {
        case .folder(let folder):
            Menu(folder.title) { folderContent(folder) }
        case .item(let item):
            Button(item.title) { onOpen(item) }
        }
    }

    /// Type-erased because folders nest to any depth.
    private func folderContent(_ folder: BookmarkTree) -> AnyView {
        AnyView(Group {
            ForEach(folder.folders) { inner in
                Menu(inner.title) { folderContent(inner) }
            }
            ForEach(folder.items) { item in
                Button(item.title) { onOpen(item) }
            }
            if !folder.folders.isEmpty || !folder.items.isEmpty { Divider() }
            newFolderButton(parent: folder.id)
            Button(L10n.string("bookmark.renameFolder")) {
                guard let id = folder.id,
                      let title = Prompts.name(L10n.string("bookmark.renameFolder"), current: folder.title, placeholder: L10n.string("bookmark.folderName"))
                else { return }
                Task { await bookmarks.renameFolder(id, to: title) }
            }
            Button(L10n.string("bookmark.deleteFolder"), role: .destructive) {
                guard let id = folder.id, Prompts.confirmDelete(String(format: L10n.string("bookmark.deleteConfirm"), folder.title), detail: L10n.string("bookmark.deleteDetail")) else { return }
                Task { await bookmarks.deleteFolder(id) }
            }
        })
    }

    private func newFolderButton(parent: Int64?) -> some View {
        Button(L10n.string("bookmark.newFolder")) {
            guard let title = Prompts.name(L10n.string("bookmark.newFolder"), current: "", placeholder: L10n.string("bookmark.folderName")) else { return }
            Task { await bookmarks.createFolder(title: title, parent: parent) }
        }
    }

    private func moveMenu(for item: BookmarkItem) -> some View {
        Menu(L10n.string("bookmark.moveTo")) {
            ForEach(bookmarks.tree.folders) { folder in
                moveTarget(folder, for: item)
            }
        }
        .disabled(bookmarks.tree.folders.isEmpty)
    }

    private func moveTarget(_ folder: BookmarkTree, for item: BookmarkItem) -> AnyView {
        AnyView(Group {
            Button(folder.title) {
                guard let id = folder.id else { return }
                Task { await bookmarks.move(item, to: id) }
            }
            ForEach(folder.folders) { moveTarget($0, for: item) }
        })
    }
}

@MainActor
public enum Prompts {
    public static func name(_ title: String, current: String, placeholder: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 260, height: 24))
        field.stringValue = current
        field.placeholderString = placeholder
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.string("password.save"))
        alert.addButton(withTitle: L10n.string("history.cancel"))
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// For deletions that remove things which cannot be brought back.
    public static func confirmDelete(_ title: String, detail: String) -> Bool {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: L10n.string("history.delete"))
        alert.addButton(withTitle: L10n.string("history.cancel"))
        return alert.runModal() == .alertFirstButtonReturn
    }
}
