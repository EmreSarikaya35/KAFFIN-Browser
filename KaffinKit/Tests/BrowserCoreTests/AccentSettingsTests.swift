import BrowserCore
import Foundation
import Testing

@MainActor
struct AccentSettingsTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "kaffin-test-\(UUID())")!
    }

    @Test func noAccentByDefault() {
        #expect(AccentSettings(defaults: makeDefaults()).color == nil)
    }

    @Test func colorSurvivesRestart() {
        let defaults = makeDefaults()
        AccentSettings(defaults: defaults).color = AccentColor(red: 0.2, green: 0.4, blue: 0.6)

        let color = AccentSettings(defaults: defaults).color
        #expect(color == AccentColor(red: 0.2, green: 0.4, blue: 0.6))
    }

    @Test func clearingReturnsToDefault() {
        let defaults = makeDefaults()
        let settings = AccentSettings(defaults: defaults)
        settings.color = AccentColor(red: 1, green: 0, blue: 0)
        settings.color = nil
        #expect(AccentSettings(defaults: defaults).color == nil)
    }
}
