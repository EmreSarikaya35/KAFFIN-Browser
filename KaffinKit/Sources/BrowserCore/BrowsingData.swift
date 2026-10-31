import Foundation

public struct HistoryEntry: Sendable, Equatable, Identifiable {
    public let url: URL
    public let title: String?
    public let visitCount: Int
    public let lastVisit: Date

    public var id: URL { url }

    public init(url: URL, title: String?, visitCount: Int, lastVisit: Date) {
        self.url = url
        self.title = title
        self.visitCount = visitCount
        self.lastVisit = lastVisit
    }
}

public struct BookmarkItem: Sendable, Equatable, Identifiable {
    public let url: URL
    public let title: String

    public var id: URL { url }

    public init(url: URL, title: String) {
        self.url = url
        self.title = title
    }
}

public struct SessionTab: Sendable, Equatable {
    public let url: URL
    public let title: String?
    public let isSelected: Bool
    /// WebKit's opaque back/forward and scroll state.
    public let interactionState: Data?

    public init(url: URL, title: String?, isSelected: Bool, interactionState: Data?) {
        self.url = url
        self.title = title
        self.isSelected = isSelected
        self.interactionState = interactionState
    }
}

public struct SessionWindow: Sendable, Equatable {
    public let tabs: [SessionTab]

    public init(tabs: [SessionTab]) {
        self.tabs = tabs
    }
}
