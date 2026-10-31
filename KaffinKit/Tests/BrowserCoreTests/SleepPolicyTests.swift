import BrowserCore
import Foundation
import Testing

@MainActor
struct PerformanceSettingsTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "kaffin-test-\(UUID())")!
    }

    @Test func automaticSleepingIsOffByDefault() {
        let settings = PerformanceSettings(defaults: makeDefaults())
        #expect(settings.profile == .standard)
        #expect(!settings.sleepsIdleTabs)
        #expect(!settings.sleepsUnderMemoryPressure)
    }

    @Test func smartEfficiencyOnlyReactsToMemoryPressure() {
        let settings = PerformanceSettings(defaults: makeDefaults())
        settings.profile = .smartEfficiency
        #expect(!settings.sleepsIdleTabs)
        #expect(settings.sleepsUnderMemoryPressure)
    }

    @Test func aggressiveSavingSleepsIdleTabs() {
        let settings = PerformanceSettings(defaults: makeDefaults())
        settings.profile = .aggressiveSaving
        #expect(settings.sleepsIdleTabs)
        #expect(settings.sleepsUnderMemoryPressure)
    }

    @Test func choicesSurviveRestart() {
        let defaults = makeDefaults()
        let settings = PerformanceSettings(defaults: defaults)
        settings.profile = .aggressiveSaving
        settings.idleMinutes = 30
        settings.protectsPinnedTabs = false
        settings.excludedSites = ["mail.example.com"]

        let again = PerformanceSettings(defaults: defaults)
        #expect(again.profile == .aggressiveSaving)
        #expect(again.idleMinutes == 30)
        #expect(!again.protectsPinnedTabs)
        #expect(again.excludedSites == ["mail.example.com"])
    }

    @Test func defaultThresholdIsFifteenMinutes() {
        #expect(PerformanceSettings(defaults: makeDefaults()).idleMinutes == 15)
    }

    @Test func parsesExcludedSitesFromText() {
        #expect(PerformanceSettings.sites(from: " WWW.Example.com, https://mail.test/inbox ,, ") == ["example.com", "mail.test"])
    }
}

struct SleepPolicyTests {
    private let now = Date(timeIntervalSinceReferenceDate: 100_000)

    private func candidate(
        idleFor minutes: Double = 60,
        isPinned: Bool = false,
        host: String? = "example.com",
        hasMedia: Bool = false,
        isCapturing: Bool = false,
        hasDownload: Bool = false,
        hasLoginPrompt: Bool = false
    ) -> SleepCandidate {
        SleepCandidate(
            lastActiveAt: now.addingTimeInterval(-minutes * 60),
            isPinned: isPinned,
            host: host,
            hasMedia: hasMedia,
            isCapturing: isCapturing,
            hasActiveDownload: hasDownload,
            hasLoginPrompt: hasLoginPrompt
        )
    }

    private func allowed(_ candidate: SleepCandidate, requiringIdle: Bool = true, protectsPinned: Bool = true, excluded: [String] = []) -> Bool {
        SleepPolicy.allows(
            candidate,
            idleMinutes: 15,
            protectsPinnedTabs: protectsPinned,
            excludedSites: excluded,
            requiringIdle: requiringIdle,
            now: now
        )
    }

    @Test func idleTabMaySleep() {
        #expect(allowed(candidate()))
    }

    @Test func recentlyUsedTabStaysAwake() {
        #expect(!allowed(candidate(idleFor: 5)))
    }

    @Test func memoryPressureIgnoresIdleTimeButNotProtections() {
        #expect(allowed(candidate(idleFor: 5), requiringIdle: false))
        #expect(!allowed(candidate(idleFor: 5, hasMedia: true), requiringIdle: false))
    }

    @Test func protectedActivityStaysAwake() {
        #expect(!allowed(candidate(hasMedia: true)))
        #expect(!allowed(candidate(isCapturing: true)))
        #expect(!allowed(candidate(hasDownload: true)))
        #expect(!allowed(candidate(hasLoginPrompt: true)))
    }

    @Test func pinnedTabFollowsItsSetting() {
        #expect(!allowed(candidate(isPinned: true)))
        #expect(allowed(candidate(isPinned: true), protectsPinned: false))
    }

    @Test func excludedSiteCoversItsSubdomains() {
        #expect(!allowed(candidate(host: "example.com"), excluded: ["example.com"]))
        #expect(!allowed(candidate(host: "www.example.com"), excluded: ["example.com"]))
        #expect(!allowed(candidate(host: "mail.example.com"), excluded: ["example.com"]))
        #expect(allowed(candidate(host: "notexample.com"), excluded: ["example.com"]))
    }
}

struct ProcessMemoryTests {
    @Test func reportsThisProcess() {
        #expect((ProcessMemory.footprint() ?? 0) > 1_000_000)
    }
}
