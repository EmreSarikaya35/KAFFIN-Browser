import Foundation
import Observation

public protocol BookmarkStoring: Sendable {
    func addBookmark(url: URL, title: String) async throws
    func removeBookmark(url: URL) async throws
    func bookmarks() async throws -> [BookmarkItem]
    func bookmarkTree() async throws -> BookmarkTree
    func addFolder(title: String, parent: Int64?) async throws -> Int64
    func renameFolder(_ id: Int64, to title: String) async throws
    func deleteFolder(_ id: Int64) async throws
    func moveBookmark(url: URL, to folder: Int64) async throws
}

/// Bookmark state shared by every window of a profile. The UI sees this, never the database.
@MainActor
@Observable
public final class BookmarksModel {
    /// Every bookmark, in any folder.
    public private(set) var items: [BookmarkItem] = []
    public private(set) var tree = BookmarkTree()
    public var isBarVisible: Bool {
        didSet { UserDefaults.standard.set(isBarVisible, forKey: Self.barVisibleKey) }
    }

    private static let barVisibleKey = "bookmarksBarVisible"
    @ObservationIgnored private let store: (any BookmarkStoring)?

    public init(store: (any BookmarkStoring)?) {
        self.store = store
        isBarVisible = UserDefaults.standard.bool(forKey: Self.barVisibleKey)
    }

    public func contains(_ url: URL?) -> Bool {
        items.contains { $0.url == url }
    }

    public func reload() async {
        guard let store else { return }
        // A failed read keeps the current list rather than showing bookmarks as lost.
        if let stored = try? await store.bookmarks() { items = stored }
        if let stored = try? await store.bookmarkTree() { tree = stored }
    }

    public func toggle(url: URL, title: String?) async {
        guard let store else { return }
        if contains(url) {
            try? await store.removeBookmark(url: url)
        } else {
            try? await store.addBookmark(url: url, title: title ?? url.host() ?? url.absoluteString)
        }
        await reload()
    }

    public func createFolder(title: String, parent: Int64?) async {
        _ = try? await store?.addFolder(title: title, parent: parent)
        await reload()
    }

    public func renameFolder(_ id: Int64, to title: String) async {
        try? await store?.renameFolder(id, to: title)
        await reload()
    }

    public func deleteFolder(_ id: Int64) async {
        try? await store?.deleteFolder(id)
        await reload()
    }

    public func move(_ item: BookmarkItem, to folder: Int64) async {
        try? await store?.moveBookmark(url: item.url, to: folder)
        await reload()
    }

    public func remove(_ item: BookmarkItem) async {
        try? await store?.removeBookmark(url: item.url)
        await reload()
    }
}
