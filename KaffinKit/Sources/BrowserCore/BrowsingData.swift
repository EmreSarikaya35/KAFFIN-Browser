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

/// A whole site across all its visited pages, for address bar completion.
public struct SiteMatch: Sendable, Equatable {
    /// The site's home page.
    public let url: URL
    /// Lowercase host without `www.`.
    public let host: String
    public let visits: Int

    public init(url: URL, host: String, visits: Int) {
        self.url = url
        self.host = host
        self.visits = visits
    }

    /// The name that groups a site's pages, or nil for addresses without a host.
    public static func siteHost(of url: URL) -> String? {
        guard var host = url.host()?.lowercased(), !host.isEmpty else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
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
    public let isPinned: Bool

    public init(url: URL, title: String?, isSelected: Bool, interactionState: Data?, isPinned: Bool = false) {
        self.url = url
        self.title = title
        self.isSelected = isSelected
        self.interactionState = interactionState
        self.isPinned = isPinned
    }
}

public struct SessionWindow: Sendable, Equatable {
    public let tabs: [SessionTab]

    public init(tabs: [SessionTab]) {
        self.tabs = tabs
    }
}
