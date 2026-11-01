import AppKit
import Foundation
import Observation
import WebKit

public enum AppTheme: String, CaseIterable, Sendable {
    case system, light, dark

    public var appearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

public enum StartupBehavior: String, CaseIterable, Sendable {
    case restore, newTab, pages
}

/// App-wide choices from Settings. Every property here changes real behavior somewhere in the app.
@MainActor
@Observable
public final class BrowserPreferences {
    public static let shared = BrowserPreferences()

    public var theme: AppTheme { didSet { apply(.theme, theme.rawValue); NSApp?.appearance = theme.appearance } }
    public var startup: StartupBehavior { didSet { apply(.startup, startup.rawValue) } }
    public var startupPages: String { didSet { apply(.startupPages, startupPages) } }
    public var showsHomeButton: Bool { didSet { apply(.showsHomeButton, showsHomeButton) } }
    public var homePage: String { didSet { apply(.homePage, homePage) } }
    public var pageZoom: Double { didSet { apply(.pageZoom, pageZoom) } }
    public var minimumFontSize: Int { didSet { apply(.minimumFontSize, minimumFontSize) } }
    public var showsSuggestions: Bool { didSet { apply(.showsSuggestions, showsSuggestions) } }
    public var offersToSavePasswords: Bool { didSet { apply(.offersToSavePasswords, offersToSavePasswords) } }
    public var offersToFillPasswords: Bool { didSet { apply(.offersToFillPasswords, offersToFillPasswords) } }
    public var warnsAboutFraud: Bool { didSet { apply(.warnsAboutFraud, warnsAboutFraud) } }
    public var alwaysUsesHTTPS: Bool { didSet { apply(.alwaysUsesHTTPS, alwaysUsesHTTPS) } }
    public var allowsJavaScript: Bool { didSet { apply(.allowsJavaScript, allowsJavaScript) } }
    public var allowsPopups: Bool { didSet { apply(.allowsPopups, allowsPopups) } }
    public var usesLockdownMode: Bool { didSet { apply(.usesLockdownMode, usesLockdownMode) } }
    public var asksWhereToSave: Bool { didSet { apply(.asksWhereToSave, asksWhereToSave) } }
    public var showsDownloadsWhenStarted: Bool { didSet { apply(.showsDownloadsWhenStarted, showsDownloadsWhenStarted) } }
    public var tabHighlightsLinks: Bool { didSet { apply(.tabHighlightsLinks, tabHighlightsLinks) } }
    public var warnsBeforeQuitting: Bool { didSet { apply(.warnsBeforeQuitting, warnsBeforeQuitting) } }
    /// A security-scoped bookmark, because the sandbox forgets a chosen folder after the app quits.
    public private(set) var downloadFolderBookmark: Data? { didSet { apply(.downloadFolder, downloadFolderBookmark) } }

    private enum Key: String {
        // The theme keeps the key of older versions, so the saved choice survives.
        case theme = "appearanceMode"
        case startup, startupPages, showsHomeButton, homePage, pageZoom, minimumFontSize, showsSuggestions
        case offersToSavePasswords, offersToFillPasswords, warnsAboutFraud, alwaysUsesHTTPS, allowsJavaScript
        case allowsPopups, usesLockdownMode, asksWhereToSave, showsDownloadsWhenStarted, tabHighlightsLinks
        case warnsBeforeQuitting, downloadFolder
    }

    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        func flag(_ key: Key, _ fallback: Bool) -> Bool { defaults.object(forKey: key.rawValue) as? Bool ?? fallback }
        theme = AppTheme(rawValue: defaults.string(forKey: Key.theme.rawValue) ?? "") ?? .system
        startup = StartupBehavior(rawValue: defaults.string(forKey: Key.startup.rawValue) ?? "") ?? .restore
        startupPages = defaults.string(forKey: Key.startupPages.rawValue) ?? ""
        showsHomeButton = flag(.showsHomeButton, false)
        homePage = defaults.string(forKey: Key.homePage.rawValue) ?? ""
        pageZoom = defaults.object(forKey: Key.pageZoom.rawValue) as? Double ?? 1
        minimumFontSize = defaults.object(forKey: Key.minimumFontSize.rawValue) as? Int ?? 0
        showsSuggestions = flag(.showsSuggestions, true)
        offersToSavePasswords = flag(.offersToSavePasswords, true)
        offersToFillPasswords = flag(.offersToFillPasswords, true)
        warnsAboutFraud = flag(.warnsAboutFraud, true)
        alwaysUsesHTTPS = flag(.alwaysUsesHTTPS, false)
        allowsJavaScript = flag(.allowsJavaScript, true)
        allowsPopups = flag(.allowsPopups, false)
        usesLockdownMode = flag(.usesLockdownMode, false)
        asksWhereToSave = flag(.asksWhereToSave, false)
        showsDownloadsWhenStarted = flag(.showsDownloadsWhenStarted, true)
        tabHighlightsLinks = flag(.tabHighlightsLinks, false)
        warnsBeforeQuitting = flag(.warnsBeforeQuitting, false)
        downloadFolderBookmark = defaults.data(forKey: Key.downloadFolder.rawValue)
    }

    private func apply(_ key: Key, _ value: Any?) {
        defaults.set(value, forKey: key.rawValue)
    }

    /// Passwords, history, bookmarks and site permissions are data, not settings, so they stay.
    public func reset() {
        theme = .system
        startup = .restore
        startupPages = ""
        showsHomeButton = false
        homePage = ""
        pageZoom = 1
        minimumFontSize = 0
        showsSuggestions = true
        offersToSavePasswords = true
        offersToFillPasswords = true
        warnsAboutFraud = true
        alwaysUsesHTTPS = false
        allowsJavaScript = true
        allowsPopups = false
        usesLockdownMode = false
        asksWhereToSave = false
        showsDownloadsWhenStarted = true
        tabHighlightsLinks = false
        warnsBeforeQuitting = false
        downloadFolderBookmark = nil
    }

    public func setDownloadFolder(_ folder: URL?) throws {
        downloadFolderBookmark = try folder?.bookmarkData(options: .withSecurityScope)
    }

    /// Nil for the system Downloads folder, or when the chosen folder no longer exists.
    public var downloadFolder: URL? {
        guard let downloadFolderBookmark else { return nil }
        var isStale = false
        return try? URL(resolvingBookmarkData: downloadFolderBookmark, options: .withSecurityScope, bookmarkDataIsStale: &isStale)
    }

    /// One value that changes with every setting a running page can pick up.
    public var pageSettingsSignature: String {
        "\(pageZoom) \(minimumFontSize) \(warnsAboutFraud) \(allowsPopups) \(tabHighlightsLinks)"
    }

    public func apply(to webView: WKWebView) {
        webView.pageZoom = pageZoom
        apply(to: webView.configuration.preferences)
    }

    public func apply(to preferences: WKPreferences) {
        preferences.minimumFontSize = CGFloat(minimumFontSize)
        preferences.isFraudulentWebsiteWarningEnabled = warnsAboutFraud
        preferences.javaScriptCanOpenWindowsAutomatically = allowsPopups
        preferences.tabFocusesLinks = tabHighlightsLinks
    }

    public var startupURLs: [URL] {
        startupPages.split(whereSeparator: \.isNewline).compactMap { AddressResolver.resolve(String($0)) }
    }

    /// Nil when a site should stay on plain http: loopback and `.local` hosts have no certificate to offer.
    public static func secureURL(for url: URL) -> URL? {
        guard url.scheme?.lowercased() == "http", let host = url.host()?.lowercased(), host.contains("."),
              host != "127.0.0.1", !host.hasSuffix(".local"),
              var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.scheme = "https"
        return parts.url
    }
}
