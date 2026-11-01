import BrowserCore
import Foundation
import Testing

@MainActor
struct BrowserPreferencesTests {
    private let defaults: UserDefaults
    private let suite = "kaffin-preferences-\(UUID())"

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    @Test func safeDefaults() {
        let settings = BrowserPreferences(defaults: defaults)

        #expect(settings.startup == .restore)
        #expect(settings.warnsAboutFraud)
        #expect(settings.allowsJavaScript)
        #expect(settings.offersToSavePasswords)
        #expect(!settings.allowsPopups)
        #expect(!settings.usesLockdownMode)
        #expect(settings.pageZoom == 1)
        defaults.removePersistentDomain(forName: suite)
    }

    @Test func choicesSurviveARestart() {
        let settings = BrowserPreferences(defaults: defaults)
        settings.theme = .dark
        settings.startup = .pages
        settings.pageZoom = 1.25
        settings.minimumFontSize = 14
        settings.allowsJavaScript = false
        settings.warnsAboutFraud = false

        let restarted = BrowserPreferences(defaults: defaults)
        #expect(restarted.theme == .dark)
        #expect(restarted.startup == .pages)
        #expect(restarted.pageZoom == 1.25)
        #expect(restarted.minimumFontSize == 14)
        #expect(!restarted.allowsJavaScript)
        #expect(!restarted.warnsAboutFraud)
        defaults.removePersistentDomain(forName: suite)
    }

    @Test func resetReachesTheSavedValuesToo() {
        let settings = BrowserPreferences(defaults: defaults)
        settings.allowsJavaScript = false
        settings.alwaysUsesHTTPS = true
        settings.startupPages = "example.com"

        settings.reset()

        let restarted = BrowserPreferences(defaults: defaults)
        #expect(restarted.allowsJavaScript)
        #expect(!restarted.alwaysUsesHTTPS)
        #expect(restarted.startupPages.isEmpty)
        defaults.removePersistentDomain(forName: suite)
    }

    @Test func startupPagesIgnoreEmptyLines() {
        let settings = BrowserPreferences(defaults: defaults)
        settings.startupPages = "https://a.example/\n\nb.example\n"

        #expect(settings.startupURLs.map(\.absoluteString) == ["https://a.example/", "https://b.example"])
        defaults.removePersistentDomain(forName: suite)
    }

    @Test(arguments: [
        ("http://example.com/a?b=1", "https://example.com/a?b=1"),
        ("http://Example.com:8080/", "https://Example.com:8080/"),
    ]) func plainAddressesAreUpgraded(from: String, to: String) throws {
        #expect(BrowserPreferences.secureURL(for: try #require(URL(string: from)))?.absoluteString == to)
    }

    @Test(arguments: ["https://example.com/", "http://localhost/", "http://127.0.0.1:8080/", "http://printer.local/", "http://intranet/", "about:blank"])
    func otherAddressesStayAsTheyAre(text: String) throws {
        #expect(BrowserPreferences.secureURL(for: try #require(URL(string: text))) == nil)
    }

    @Test func clearRangesCountBackFromNow() {
        let now = Date(timeIntervalSince1970: 1_000_000)

        #expect(ClearDataRange.hour.startDate(now: now) == now.addingTimeInterval(-3600))
        #expect(ClearDataRange.week.startDate(now: now) == now.addingTimeInterval(-604_800))
        #expect(ClearDataRange.all.startDate(now: now) == .distantPast)
    }
}
