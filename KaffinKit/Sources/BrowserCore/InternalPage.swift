import Foundation

/// A KAFFIN page shown in a tab. Only the browser itself can open one, because the
/// `kaffin` scheme never reaches a tab through a page's own navigation.
public enum InternalPage: String, CaseIterable, Sendable {
    case settings
    case history

    public static let scheme = "kaffin"

    public init?(url: URL) {
        guard url.scheme?.lowercased() == Self.scheme, let page = url.host().flatMap(Self.init(rawValue:)) else { return nil }
        self = page
    }

    public var url: URL {
        URL(string: "\(Self.scheme)://\(rawValue)")!
    }

    public var title: String {
        L10n.string(self == .settings ? "settings.title" : "history.title")
    }
}
