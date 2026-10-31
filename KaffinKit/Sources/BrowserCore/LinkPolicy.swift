/// Decides what a navigation may do, whatever the page wants.
public enum LinkPolicy {
    public enum Decision: Sendable, Equatable {
        case allow
        case block
        case askToOpenApp
    }

    private static let webSchemes: Set<String> = ["http", "https", "about", "blob"]
    private static let blockedSchemes: Set<String> = ["file", "javascript", "vbscript"]

    public static func decision(scheme: String, isMainFrame: Bool, isLinkClick: Bool) -> Decision {
        let scheme = scheme.lowercased()
        if webSchemes.contains(scheme) { return .allow }
        // A `data:` page has no address of its own to check, which makes it a phishing tool.
        if scheme == "data" { return isMainFrame ? .block : .allow }
        if blockedSchemes.contains(scheme) { return .block }
        // Pages must not launch apps on their own, or without the user seeing which app.
        return isLinkClick ? .askToOpenApp : .block
    }
}
