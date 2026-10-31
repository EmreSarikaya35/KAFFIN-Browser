import Foundation

public struct SearchEngine: Sendable, Equatable {
    public let name: String
    public let queryTemplate: String

    public init(name: String, queryTemplate: String) {
        self.name = name
        self.queryTemplate = queryTemplate
    }

    public static let google = SearchEngine(name: "Google", queryTemplate: "https://www.google.com/search?q=%s")

    public func url(for query: String) -> URL? {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=#?")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
        return URL(string: queryTemplate.replacingOccurrences(of: "%s", with: encoded))
    }
}

/// Turns address bar input into a URL to load.
public enum AddressResolver {
    // javascript: and data: are left out on purpose, so pasted input cannot run script in the current page.
    private static let allowedSchemes: Set<String> = ["http", "https", "about"]

    public static func resolve(_ input: String, searchEngine: SearchEngine = .google) -> URL? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }

        if text.rangeOfCharacter(from: .whitespacesAndNewlines) == nil {
            if let url = URL(string: text), let scheme = url.scheme?.lowercased(), allowedSchemes.contains(scheme) {
                return url
            }
            if let url = hostURL(text) {
                return url
            }
        }
        return searchEngine.url(for: text)
    }

    private static func hostURL(_ text: String) -> URL? {
        let authority = text.prefix { !"/?#".contains($0) }
        let parts = authority.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count <= 2, let host = parts.first?.lowercased() else { return nil }
        if parts.count == 2, parts[1].isEmpty || !parts[1].allSatisfy(\.isNumber) { return nil }

        let labels = host.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        if host == "localhost" || isIPv4(labels) {
            return URL(string: "http://\(text)")
        }
        guard labels.count >= 2, labels.allSatisfy(isHostLabel), let tld = labels.last,
              tld.count >= 2, tld.allSatisfy(\.isLetter) else { return nil }
        return URL(string: "https://\(text)")
    }

    private static func isIPv4(_ labels: [String]) -> Bool {
        labels.count == 4 && labels.allSatisfy { UInt8($0) != nil }
    }

    private static func isHostLabel(_ label: String) -> Bool {
        !label.isEmpty && !label.hasPrefix("-") && !label.hasSuffix("-")
            && label.allSatisfy { $0 == "-" || $0.isLetter || $0.isNumber }
    }
}
