import Foundation

public enum ConnectionSecurity: Sendable, Equatable {
    case none
    case secure
    case notSecure
}

/// What the address bar shows while it is not being edited.
public enum AddressDisplay {
    public static func text(for url: URL?) -> String {
        guard let url, url.scheme != "about" else { return "" }
        var text = url.absoluteString
        if text.hasPrefix("https://") { text.removeFirst("https://".count) }
        if url.path() == "/", url.query() == nil, url.fragment() == nil, text.hasSuffix("/") { text.removeLast() }
        return text
    }

    public static func security(of url: URL?) -> ConnectionSecurity {
        switch url?.scheme {
        case "https": .secure
        case "http": .notSecure
        default: .none
        }
    }
}
