import Foundation
import Observation

public protocol BookmarkStoring: Sendable {
    func addBookmark(url: URL, title: String) async throws
    func removeBookmark(url: URL) async throws
    func bookmarks() async throws -> [BookmarkItem]
}

/// Bookmark state shared by every window of a profile. The UI sees this, never the database.
@MainActor
@Observable
public final class BookmarksModel {
    public private(set) var items: [BookmarkItem] = []
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

    public func remove(_ item: BookmarkItem) async {
        try? await store?.removeBookmark(url: item.url)
        await reload()
    }
}
