import BrowserCore
import Foundation
import Testing

@MainActor
struct SearchEngineTests {
    private func makeSettings() -> SearchSettings {
        SearchSettings(defaults: UserDefaults(suiteName: "kaffin-test-\(UUID())")!)
    }

    @Test func googleIsDefault() {
        #expect(makeSettings().engine == .google)
    }

    @Test(arguments: [
        ("Bing", "https://www.bing.com/search?q=kahve"),
        ("DuckDuckGo", "https://duckduckgo.com/?q=kahve"),
        ("Brave Search", "https://search.brave.com/search?q=kahve"),
    ])
    func builtInEnginesBuildSearchAddress(name: String, expected: String) throws {
        let engine = try #require(SearchEngine.builtIn.first { $0.name == name })
        #expect(engine.url(for: "kahve")?.absoluteString == expected)
    }

    @Test func selectionPersists() {
        let defaults = UserDefaults(suiteName: "kaffin-test-\(UUID())")!
        SearchSettings(defaults: defaults).select(.duckDuckGo)
        #expect(SearchSettings(defaults: defaults).engine == .duckDuckGo)
    }

    @Test(arguments: [
        ("https://kagi.com/search?q=%s", true),
        ("http://kagi.com/search?q=%s", false),
        ("https://kagi.com/search", false),
        ("javascript:alert('%s')", false),
        ("", false),
    ])
    func customTemplateMustBeHTTPSWithPlaceholder(template: String, isValid: Bool) {
        let settings = makeSettings()
        #expect(settings.setCustom(template: template) == isValid)
        #expect((settings.engine.queryTemplate == template) == isValid)
    }

    @Test func customEngineSurvivesRestart() {
        let defaults = UserDefaults(suiteName: "kaffin-test-\(UUID())")!
        _ = SearchSettings(defaults: defaults).setCustom(template: "https://kagi.com/search?q=%s")
        #expect(SearchSettings(defaults: defaults).engine.queryTemplate == "https://kagi.com/search?q=%s")
    }
}
