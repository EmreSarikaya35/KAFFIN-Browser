import BrowserCore
import Foundation
import Testing
import WebKit
@testable import Tabs

/// Runs real WebKit against a local server, with no window. Proves the delegates are really called.
@MainActor
@Suite(.serialized)
struct WebKitIntegrationTests {
    private let folder: URL
    private let downloads: DownloadManager
    private let manager: TabManager

    init() throws {
        // The suite is serialized, and two tests check this shared folder ends up empty.
        try? FileManager.default.removeItem(at: DownloadManager.stagingRoot)
        folder = FileManager.default.temporaryDirectory.appending(path: "kaffin-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        downloads = DownloadManager(directory: folder)
        manager = TabManager(factory: WebViewFactory(profileID: UUID()), downloads: downloads)
    }

    private func wait(_ what: Comment, until condition: () -> Bool) async throws {
        for _ in 0..<500 where !condition() {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(condition(), what)
    }

    @Test func finishedPageIsReportedAsVisit() async throws {
        let server = try await LocalTestServer()
        let page = server.baseURL.appending(path: "page")
        var visits: [URL] = []
        var titles: [String] = []
        manager.onPageVisit = { url, _ in visits.append(url) }
        manager.onPageTitle = { _, title in titles.append(title) }

        manager.newTab(url: page)
        try await wait("visit and title") { !visits.isEmpty && titles.contains("Test Page") }
        #expect(visits == [page])
    }

    @Test func attachmentBecomesDownloadInChosenFolder() async throws {
        let server = try await LocalTestServer()
        manager.newTab(url: server.baseURL.appending(path: "file"))

        try await wait("download finished") { downloads.items.first?.state == .finished }
        let file = folder.appending(path: "report.bin")
        #expect(FileManager.default.contents(atPath: file.path(percentEncoded: false))?.count == 2048)
    }

    @Test func closingTabKeepsDownloadRunning() async throws {
        let server = try await LocalTestServer()
        let tab = manager.newTab(url: server.baseURL.appending(path: "slow"))
        try await wait("download started") { !downloads.items.isEmpty }

        manager.close(tab.id)
        try await wait("download finished after close") { downloads.items.first?.state == .finished }
        #expect(FileManager.default.contents(atPath: folder.appending(path: "report.bin").path(percentEncoded: false))?.count == 2048)
    }

    @Test func fileCreatedDuringDownloadIsNotOverwritten() async throws {
        let server = try await LocalTestServer()
        manager.newTab(url: server.baseURL.appending(path: "slow"))
        try await wait("download started") { !downloads.items.isEmpty }

        let existing = folder.appending(path: "report.bin")
        try Data("mine".utf8).write(to: existing)
        try await wait("download finished") { downloads.items.first?.state == .finished }

        #expect(FileManager.default.contents(atPath: existing.path(percentEncoded: false)) == Data("mine".utf8))
        #expect(downloads.items.first?.fileName == "report (1).bin")
        #expect(downloads.items.first?.destination == folder.appending(path: "report (1).bin"))
    }

    @Test func finishedDownloadIsQuarantinedAndLeavesNoStagingFolder() async throws {
        let server = try await LocalTestServer()
        manager.newTab(url: server.baseURL.appending(path: "file"))
        try await wait("download finished") { downloads.items.first?.state == .finished }

        let file = try #require(downloads.items.first?.destination)
        let values = try file.resourceValues(forKeys: [.quarantinePropertiesKey])
        #expect(values.quarantineProperties != nil)
        let staging = try FileManager.default.contentsOfDirectory(at: DownloadManager.stagingRoot, includingPropertiesForKeys: nil)
        #expect(staging.isEmpty)
    }

    @Test func cancelledDownloadLeavesNoFile() async throws {
        let server = try await LocalTestServer()
        manager.newTab(url: server.baseURL.appending(path: "slow"))
        try await wait("download started") { downloads.items.first?.fileName == "report.bin" }

        let item = try #require(downloads.items.first)
        downloads.cancel(item)
        #expect(item.state == .cancelled)
        try await Task.sleep(for: .milliseconds(1200))
        #expect(!FileManager.default.fileExists(atPath: folder.appending(path: "report.bin").path(percentEncoded: false)))
    }

    private func file(_ name: String = "report.bin") -> Data? {
        FileManager.default.contents(atPath: folder.appending(path: name).path(percentEncoded: false))
    }

    @Test func pausedDownloadResumesFromWhereItStopped() async throws {
        let server = try await LocalTestServer()
        let downloads = DownloadManager(directory: folder, factory: WebViewFactory(profileID: UUID()))
        let manager = TabManager(factory: WebViewFactory(profileID: UUID()), downloads: downloads)
        manager.newTab(url: server.baseURL.appending(path: "resumable"))
        try await wait("download started") { downloads.items.first?.fileName == "report.bin" }
        try await Task.sleep(for: .milliseconds(300))

        let item = try #require(downloads.items.first)
        await downloads.pause(item)
        #expect(item.state == .paused)
        #expect(file() == nil, "A paused file stays out of the Downloads folder")

        await downloads.resume(item)
        try await wait("download finished") { item.state == .finished }
        #expect(file() == Data(repeating: 120, count: 2048))
        #expect(server.rangeRequests.count == 1, "Resuming asks only for the missing bytes")
        #expect(item.receivedBytes == 2048)
        #expect(item.totalBytes == 2048)
    }

    @Test func resumingRightAfterPauseStillContinues() async throws {
        let server = try await LocalTestServer()
        let downloads = DownloadManager(directory: folder, factory: WebViewFactory(profileID: UUID()))
        let manager = TabManager(factory: WebViewFactory(profileID: UUID()), downloads: downloads)
        manager.newTab(url: server.baseURL.appending(path: "resumable"))
        try await wait("download started") { downloads.items.first?.fileName == "report.bin" }
        try await Task.sleep(for: .milliseconds(300))

        let item = try #require(downloads.items.first)
        let pausing = Task { await downloads.pause(item) }
        while item.state != .paused { await Task.yield() }
        await downloads.resume(item)
        await pausing.value

        try await wait("download finished") { item.state == .finished }
        #expect(file() == Data(repeating: 120, count: 2048))
        #expect(server.rangeRequests.first ?? 0 > 0, "Continues from the bytes it already has")
    }

    @Test func pausedDownloadSaysWhenItMustStartOver() async throws {
        let server = try await LocalTestServer()
        let downloads = DownloadManager(directory: folder, factory: WebViewFactory(profileID: UUID()))
        let manager = TabManager(factory: WebViewFactory(profileID: UUID()), downloads: downloads)
        manager.newTab(url: server.baseURL.appending(path: "slow"))
        try await wait("download started") { downloads.items.first?.fileName == "report.bin" }

        let item = try #require(downloads.items.first)
        await downloads.pause(item)
        #expect(!item.canContinue, "This server sends no validator, so WebKit cannot continue")
        downloads.remove(item)
    }

    @Test func serverWithoutResumeSupportRestartsCleanly() async throws {
        let server = try await LocalTestServer()
        let downloads = DownloadManager(directory: folder, factory: WebViewFactory(profileID: UUID()))
        let manager = TabManager(factory: WebViewFactory(profileID: UUID()), downloads: downloads)
        manager.newTab(url: server.baseURL.appending(path: "slow"))
        try await wait("download started") { downloads.items.first?.fileName == "report.bin" }

        let item = try #require(downloads.items.first)
        await downloads.pause(item)
        await downloads.resume(item)

        try await wait("download finished") { item.state == .finished }
        #expect(file()?.count == 2048)
    }

    @Test func cancelledDownloadCanBeRetried() async throws {
        let server = try await LocalTestServer()
        let downloads = DownloadManager(directory: folder, factory: WebViewFactory(profileID: UUID()))
        let manager = TabManager(factory: WebViewFactory(profileID: UUID()), downloads: downloads)
        manager.newTab(url: server.baseURL.appending(path: "slow"))
        try await wait("download started") { downloads.items.first?.fileName == "report.bin" }

        let item = try #require(downloads.items.first)
        downloads.cancel(item)
        await downloads.resume(item)

        try await wait("download finished") { item.state == .finished }
        #expect(file()?.count == 2048)
    }

    @Test func removingPausedDownloadLeavesNoStagedFile() async throws {
        let server = try await LocalTestServer()
        let downloads = DownloadManager(directory: folder, factory: WebViewFactory(profileID: UUID()))
        let manager = TabManager(factory: WebViewFactory(profileID: UUID()), downloads: downloads)
        manager.newTab(url: server.baseURL.appending(path: "resumable"))
        try await wait("download started") { downloads.items.first?.fileName == "report.bin" }

        let item = try #require(downloads.items.first)
        await downloads.pause(item)
        downloads.remove(item)

        #expect(downloads.items.isEmpty)
        let staged = try FileManager.default.contentsOfDirectory(at: DownloadManager.stagingRoot, includingPropertiesForKeys: nil)
        #expect(staged.isEmpty)
    }

    @Test func finishedDownloadReportsItsSize() async throws {
        let server = try await LocalTestServer()
        manager.newTab(url: server.baseURL.appending(path: "file"))
        try await wait("download finished") { downloads.items.first?.state == .finished }

        #expect(downloads.items.first?.receivedBytes == 2048)
        #expect(downloads.items.first?.totalBytes == 2048)
    }

    private func openBackgroundPage(_ server: LocalTestServer, path: String = "page") async throws -> Tab {
        let tab = manager.newTab(url: server.baseURL.appending(path: path))
        try await wait("page") { tab.title != nil && !tab.isLoading }
        manager.newTab()
        return tab
    }

    @Test func sleepingTabReleasesItsPageAndKeepsItsIdentity() async throws {
        let server = try await LocalTestServer()
        let tab = try await openBackgroundPage(server)
        manager.togglePin(tab.id)
        let old = tab.webView
        let url = tab.url

        #expect(manager.sleep(tab.id))

        #expect(tab.state == .sleeping)
        #expect(tab.webView !== old)
        #expect(tab.webView.url == nil, "The new WebView holds no page, so WebKit can drop the old one")
        #expect(tab.url == url)
        #expect(tab.title == "Test Page")
        #expect(tab.isPinned)
    }

    @Test func selectingSleepingTabRestoresPageAndBackHistory() async throws {
        let server = try await LocalTestServer()
        let tab = manager.newTab(url: server.baseURL.appending(path: "page"))
        try await wait("first page") { tab.title == "Test Page" && !tab.isLoading }
        tab.load(server.baseURL.appending(path: "iconpage"))
        try await wait("second page") { tab.title == "Icon" && !tab.isLoading && tab.canGoBack }
        manager.newTab()
        #expect(manager.sleep(tab.id))

        manager.select(tab.id)
        #expect(tab.state == .restoring)
        try await wait("restored") { tab.state == .active && !tab.isLoading }
        #expect(tab.title == "Icon")
        #expect(tab.canGoBack)
    }

    @Test func activeTabCannotSleep() async throws {
        let server = try await LocalTestServer()
        let tab = manager.newTab(url: server.baseURL.appending(path: "page"))
        try await wait("page") { tab.title != nil }
        #expect(!manager.sleep(tab.id))
        #expect(tab.state == .active)
    }

    @Test func blankTabCannotSleep() {
        let blank = manager.newTab(select: false)
        manager.newTab()
        #expect(!manager.sleep(blank.id))
    }

    @Test func sleepingTabSurvivesInSession() async throws {
        let server = try await LocalTestServer()
        let tab = try await openBackgroundPage(server)
        let url = tab.url
        #expect(manager.sleep(tab.id))

        #expect(manager.snapshot().tabs.first?.url == url)
        #expect(manager.snapshot().tabs.first?.interactionState != nil)
    }

    @Test func downloadSurvivesItsTabSleeping() async throws {
        let server = try await LocalTestServer()
        let tab = manager.newTab(url: server.baseURL.appending(path: "page"))
        try await wait("page") { tab.title != nil && !tab.isLoading }
        tab.load(server.baseURL.appending(path: "slow"))
        try await wait("download started") { !downloads.items.isEmpty }
        manager.newTab()

        #expect(manager.sleep(tab.id))
        try await wait("download finished") { downloads.items.first?.state == .finished }
    }

    private func automaticSettings(_ profile: OptimizationProfile) -> PerformanceSettings {
        let settings = PerformanceSettings(defaults: UserDefaults(suiteName: "kaffin-test-\(UUID())")!)
        settings.profile = profile
        return settings
    }

    private var afterIdle: Date { Date.now.addingTimeInterval(3600) }

    @Test func standardProfileNeverSleepsTabsAutomatically() async throws {
        let server = try await LocalTestServer()
        let tab = try await openBackgroundPage(server)

        await manager.sleepEligibleTabs(automaticSettings(.standard), trigger: .idle, now: afterIdle)
        await manager.sleepEligibleTabs(automaticSettings(.standard), trigger: .memoryPressure, now: afterIdle)
        #expect(tab.state == .background)
    }

    @Test func smartEfficiencyIgnoresIdleButAnswersMemoryPressure() async throws {
        let server = try await LocalTestServer()
        let tab = try await openBackgroundPage(server)
        let settings = automaticSettings(.smartEfficiency)

        await manager.sleepEligibleTabs(settings, trigger: .idle, now: afterIdle)
        #expect(tab.state == .background)

        await manager.sleepEligibleTabs(settings, trigger: .memoryPressure, now: .now)
        #expect(tab.state == .sleeping)
    }

    @Test func aggressiveSavingSleepsIdleTabsOnly() async throws {
        let server = try await LocalTestServer()
        let tab = try await openBackgroundPage(server)
        let settings = automaticSettings(.aggressiveSaving)

        await manager.sleepEligibleTabs(settings, trigger: .idle, now: .now)
        #expect(tab.state == .background)

        await manager.sleepEligibleTabs(settings, trigger: .idle, now: afterIdle)
        #expect(tab.state == .sleeping)
    }

    @Test func refusedConnectionShowsErrorPageAndRecordsNoVisit() async throws {
        var visits = 0
        var titles: [String] = []
        manager.onPageVisit = { _, _ in visits += 1 }
        manager.onPageTitle = { _, title in titles.append(title) }
        let failed = URL(string: "http://127.0.0.1:9/nothing")!

        let tab = manager.newTab(url: failed)
        try await wait("error page") { tab.isShowingError && !tab.isLoading }
        #expect(tab.url == failed)
        #expect(tab.title == "127.0.0.1")
        #expect(visits == 0)
        #expect(titles.isEmpty)
    }

    @Test func successfulLoadClearsErrorState() async throws {
        let server = try await LocalTestServer()
        let tab = manager.newTab(url: URL(string: "http://127.0.0.1:9/nothing"))
        _ = tab
        try await wait("error page") { manager.tabs[0].isShowingError && !manager.tabs[0].isLoading }

        manager.tabs[0].load(server.baseURL.appending(path: "page"))
        try await wait("real page") { manager.tabs[0].title == "Test Page" }
        #expect(!manager.tabs[0].isShowingError)
    }

    @Test func declaredIconBecomesTabFavicon() async throws {
        let server = try await LocalTestServer()
        let manager = TabManager(
            factory: WebViewFactory(profileID: UUID()),
            downloads: downloads,
            favicons: FaviconLoader(store: nil)
        )
        let tab = manager.newTab(url: server.baseURL.appending(path: "iconpage"))
        try await wait("favicon") { tab.favicon != nil }
    }

    @Test func missingDeclarationFallsBackToFaviconIco() async throws {
        let server = try await LocalTestServer()
        let manager = TabManager(
            factory: WebViewFactory(profileID: UUID()),
            downloads: downloads,
            favicons: FaviconLoader(store: nil)
        )
        let tab = manager.newTab(url: server.baseURL.appending(path: "page"))
        try await wait("favicon") { tab.favicon != nil }
    }

    @Test func navigatingToAnotherHostDropsOldIcon() async throws {
        let server = try await LocalTestServer()
        let manager = TabManager(
            factory: WebViewFactory(profileID: UUID()),
            downloads: downloads,
            favicons: FaviconLoader(store: nil)
        )
        let tab = manager.newTab(url: server.baseURL.appending(path: "iconpage"))
        try await wait("favicon") { tab.favicon != nil }

        tab.load(URL(string: "about:blank")!)
        try await wait("icon cleared") { tab.favicon == nil }
    }

    @Test func tabsWithoutLoaderRequestNoIcon() async throws {
        let server = try await LocalTestServer()
        let tab = manager.newTab(url: server.baseURL.appending(path: "iconpage"))
        try await wait("page loaded") { !tab.isLoading && tab.title != nil }
        try await Task.sleep(for: .milliseconds(200))
        #expect(tab.favicon == nil)
        #expect(!server.requestedPaths.contains("/icon.png"))
    }

    private func audioMuted(_ tab: Tab, _ selector: String = "#a") async throws -> Bool? {
        try await tab.webView.evaluateJavaScript("document.querySelector('\(selector)').muted") as? Bool
    }

    @Test func mutingSilencesExistingMediaAndUnmuteRestoresIt() async throws {
        let server = try await LocalTestServer()
        let tab = manager.newTab(url: server.baseURL.appending(path: "media"))
        try await wait("page") { tab.title == "Media" && !tab.isLoading }

        await manager.toggleMute(tab.id)
        #expect(tab.isMuted)
        #expect(try await audioMuted(tab) == true)

        await manager.toggleMute(tab.id)
        #expect(!tab.isMuted)
        #expect(try await audioMuted(tab) == false)
    }

    @Test func unmuteLeavesMediaThePageMutedItself() async throws {
        let server = try await LocalTestServer()
        let tab = manager.newTab(url: server.baseURL.appending(path: "media"))
        try await wait("page") { tab.title == "Media" && !tab.isLoading }

        await manager.toggleMute(tab.id)
        await manager.toggleMute(tab.id)
        #expect(try await audioMuted(tab, "#pageMuted") == true)
    }

    // YouTube keeps one player between videos, and the player restores its own volume state.
    @Test func muteHoldsWhenPageUnmutesItsPlayer() async throws {
        let server = try await LocalTestServer()
        let tab = manager.newTab(url: server.baseURL.appending(path: "media"))
        try await wait("page") { tab.title == "Media" && !tab.isLoading }
        await manager.toggleMute(tab.id)

        _ = try await tab.webView.evaluateJavaScript("document.querySelector('#a').muted = false; 1")
        try await Task.sleep(for: .milliseconds(200))
        #expect(try await audioMuted(tab) == true)
    }

    @Test func muteReachesMediaAddedByThePageLater() async throws {
        let server = try await LocalTestServer()
        let tab = manager.newTab(url: server.baseURL.appending(path: "media"))
        try await wait("page") { tab.title == "Media" && !tab.isLoading }
        await manager.toggleMute(tab.id)

        // Without a window the page is hidden and WebKit never starts loading media, so the event is sent by hand.
        _ = try await tab.webView.evaluateJavaScript("""
        const late = document.createElement('audio');
        late.id = 'late';
        document.body.append(late);
        late.dispatchEvent(new Event('loadstart')); 1
        """)
        #expect(try await audioMuted(tab, "#late") == true)
    }

    @Test func unmutedTabLeavesPageSoundAlone() async throws {
        let server = try await LocalTestServer()
        let tab = manager.newTab(url: server.baseURL.appending(path: "media"))
        try await wait("page") { tab.title == "Media" && !tab.isLoading }
        await manager.toggleMute(tab.id)
        await manager.toggleMute(tab.id)

        _ = try await tab.webView.evaluateJavaScript("document.querySelector('#a').muted = true; 1")
        _ = try await tab.webView.evaluateJavaScript("document.querySelector('#a').muted = false; 1")
        try await Task.sleep(for: .milliseconds(200))
        #expect(try await audioMuted(tab) == false)
    }

    @Test func muteCarriesOverToNextPage() async throws {
        let server = try await LocalTestServer()
        let tab = manager.newTab(url: server.baseURL.appending(path: "media"))
        try await wait("page") { tab.title == "Media" && !tab.isLoading }
        await manager.toggleMute(tab.id)

        tab.load(URL(string: "\(server.baseURL.absoluteString)/media?next")!)
        try await wait("next page muted") {
            tab.url?.query() == "next" && !tab.isLoading
        }
        try await Task.sleep(for: .milliseconds(200))
        #expect(try await audioMuted(tab) == true)
    }

    @Test func movedTabKeepsItsPageAndReportsToNewWindow() async throws {
        let server = try await LocalTestServer()
        let target = TabManager(factory: WebViewFactory(profileID: UUID()), downloads: downloads)
        _ = manager.newTab()
        let tab = manager.newTab(url: server.baseURL.appending(path: "page"))
        try await wait("page") { tab.title == "Test Page" && !tab.isLoading }

        var oldVisits = 0
        var newVisits = 0
        manager.onPageVisit = { _, _ in oldVisits += 1 }
        target.onPageVisit = { _, _ in newVisits += 1 }
        target.adopt(try #require(manager.detachTab(tab.id)))

        try await Task.sleep(for: .milliseconds(200))
        #expect(server.requestedPaths.filter { $0 == "/page" }.count == 1, "Moving must not reload the page")

        tab.load(server.baseURL.appending(path: "iconpage"))
        try await wait("visit in new window") { newVisits == 1 }
        #expect(oldVisits == 0)
    }

    @Test func loginBridgeFollowsMovedTabAfterOldWindowCloses() async throws {
        let server = try await LocalTestServer()
        let store = InMemoryCredentialStore()
        let target = makeLoginManager(store: store)
        var source: TabManager? = makeLoginManager(store: store)
        _ = source?.newTab()
        let tab = try await loadedTab(source!, server.baseURL.appending(path: "login"))

        target.adopt(try #require(source?.detachTab(tab.id)))
        source = nil

        _ = try await tab.webView.evaluateJavaScript("""
        document.getElementById('u').value = 'ada';
        document.getElementById('p').value = 'secret';
        document.getElementById('f').requestSubmit(); 1
        """)
        try await wait("save prompt in new window") { tab.loginPrompt != nil }
        await target.acceptLoginPrompt(on: tab)
        #expect(await store.saved.values.contains("secret"))
    }

    private final class FakeDialogs: PageDialogPresenting {
        var alerts: [String] = []
        var confirmAnswer = false
        var promptAnswer: String?
        var credential: URLCredential?
        var authRequests: [String] = []

        func alert(_ message: String, from site: String) async {
            alerts.append(message)
        }

        func confirm(_ message: String, from site: String) async -> Bool {
            confirmAnswer
        }

        func prompt(_ message: String, defaultText: String?, from site: String) async -> String? {
            promptAnswer ?? defaultText
        }

        func credential(for site: String, realm: String?) async -> URLCredential? {
            authRequests.append(realm ?? "")
            return credential
        }

        func confirmOpening(_ url: URL, from site: String) async -> Bool {
            false
        }

        var permissionAnswer: PermissionAnswer = .notNow
        var permissionRequests = 0
        var systemLocationAllowed = true
        var systemLocationChecks = 0

        func ensureSystemLocationAccess() async -> Bool {
            systemLocationChecks += 1
            return systemLocationAllowed
        }

        func askPermission(_ kind: SitePermissionKind, for site: String) async -> PermissionAnswer {
            permissionRequests += 1
            return permissionAnswer
        }
    }

    private actor MemoryPermissions: SitePermissionStoring {
        var saved: [String: Bool] = [:]

        func sitePermission(_ kind: SitePermissionKind, site: String) -> Bool? {
            saved["\(kind.rawValue)|\(site)"]
        }

        func setSitePermission(_ kind: SitePermissionKind, site: String, allowed: Bool) {
            saved["\(kind.rawValue)|\(site)"] = allowed
        }

        func removeSitePermission(_ kind: SitePermissionKind, site: String) {
            saved["\(kind.rawValue)|\(site)"] = nil
        }

        func allSitePermissions() -> [SitePermission] { [] }
    }

    @Test func allowedSiteIsRememberedAndAskedOnce() async {
        let dialogs = FakeDialogs()
        dialogs.permissionAnswer = .allow
        let store = MemoryPermissions()
        let manager = TabManager(factory: WebViewFactory(profileID: UUID()), sitePermissions: store)
        manager.dialogs = dialogs

        #expect(await manager.decidePermission(.camera, site: "https://meet.example"))
        #expect(await manager.decidePermission(.camera, site: "https://meet.example"))
        #expect(dialogs.permissionRequests == 1)
    }

    @Test func blockedSiteStaysBlockedWithoutAsking() async {
        let dialogs = FakeDialogs()
        dialogs.permissionAnswer = .block
        let store = MemoryPermissions()
        let manager = TabManager(factory: WebViewFactory(profileID: UUID()), sitePermissions: store)
        manager.dialogs = dialogs

        #expect(await !manager.decidePermission(.microphone, site: "https://x.example"))
        #expect(await !manager.decidePermission(.microphone, site: "https://x.example"))
        #expect(dialogs.permissionRequests == 1)
    }

    @Test func locationNeedsTheSystemToAgreeToo() async {
        let dialogs = FakeDialogs()
        dialogs.permissionAnswer = .allow
        dialogs.systemLocationAllowed = false
        let store = MemoryPermissions()
        let manager = TabManager(factory: WebViewFactory(profileID: UUID()), sitePermissions: store)
        manager.dialogs = dialogs

        #expect(await !manager.decidePermission(.location, site: "https://maps.example"))
        #expect(dialogs.systemLocationChecks == 1)
        #expect(await store.saved["location|https://maps.example"] == true, "The site choice stays for when macOS allows it")

        dialogs.systemLocationAllowed = true
        #expect(await manager.decidePermission(.location, site: "https://maps.example"))
        #expect(dialogs.permissionRequests == 1)
    }

    @Test func refusedSiteNeverTriggersTheSystemQuestion() async {
        let dialogs = FakeDialogs()
        dialogs.permissionAnswer = .block
        let manager = TabManager(factory: .privateSession())
        manager.dialogs = dialogs

        #expect(await !manager.decidePermission(.location, site: "https://maps.example"))
        #expect(dialogs.systemLocationChecks == 0)
    }

    @Test func cameraDoesNotInvolveLocationAccess() async {
        let dialogs = FakeDialogs()
        dialogs.permissionAnswer = .allow
        let manager = TabManager(factory: .privateSession())
        manager.dialogs = dialogs

        #expect(await manager.decidePermission(.camera, site: "https://meet.example"))
        #expect(dialogs.systemLocationChecks == 0)
    }

    @Test func notNowIsNotRemembered() async {
        let dialogs = FakeDialogs()
        let store = MemoryPermissions()
        let manager = TabManager(factory: WebViewFactory(profileID: UUID()), sitePermissions: store)
        manager.dialogs = dialogs

        #expect(await !manager.decidePermission(.location, site: "https://x.example"))
        #expect(await !manager.decidePermission(.location, site: "https://x.example"))
        #expect(dialogs.permissionRequests == 2)
    }

    @Test func privateWindowDecisionsAreNeverStored() async {
        let dialogs = FakeDialogs()
        dialogs.permissionAnswer = .allow
        let manager = TabManager(factory: .privateSession())
        manager.dialogs = dialogs

        #expect(await manager.decidePermission(.camera, site: "https://x.example"))
        #expect(await manager.decidePermission(.camera, site: "https://x.example"))
        #expect(dialogs.permissionRequests == 2)
    }

    @Test func withoutAWindowToAskInTheAnswerIsNo() async {
        #expect(await !manager.decidePermission(.camera, site: "https://x.example"))
    }

    /// A misnamed delegate method compiles and is then silently never called, so the names are pinned here.
    @Test(arguments: [
        "webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:",
        "webView:requestGeolocationPermissionForOrigin:initiatedByFrame:decisionHandler:",
        "webView:runJavaScriptAlertPanelWithMessage:initiatedByFrame:completionHandler:",
        "webView:runJavaScriptConfirmPanelWithMessage:initiatedByFrame:completionHandler:",
        "webView:runJavaScriptTextInputPanelWithPrompt:defaultText:initiatedByFrame:completionHandler:",
        "webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:",
        "webView:runOpenPanelWithParameters:initiatedByFrame:completionHandler:",
    ])
    func uiDelegateImplements(selector: String) {
        let delegate = manager.newTab().webView.uiDelegate
        #expect(delegate?.responds(to: NSSelectorFromString(selector)) == true)
    }

    @Test(arguments: [
        "webView:decidePolicyForNavigationAction:decisionHandler:",
        "webView:decidePolicyForNavigationResponse:decisionHandler:",
        "webView:didReceiveAuthenticationChallenge:completionHandler:",
        "webView:didFailProvisionalNavigation:withError:",
        "webView:didFailNavigation:withError:",
        "webView:didCommitNavigation:",
        "webView:didFinishNavigation:",
        "webViewWebContentProcessDidTerminate:",
        "webView:navigationAction:didBecomeDownload:",
        "webView:navigationResponse:didBecomeDownload:",
    ])
    func navigationDelegateImplements(selector: String) {
        let delegate = manager.newTab().webView.navigationDelegate
        #expect(delegate?.responds(to: NSSelectorFromString(selector)) == true)
    }

    @Test func closedTabLeavesMemory() async throws {
        let server = try await LocalTestServer()
        weak var released: Tab?
        weak var releasedView: WKWebView?
        do {
            let tab = manager.newTab(url: server.baseURL.appending(path: "page"))
            try await wait("page") { tab.title != nil && !tab.isLoading }
            manager.newTab()
            released = tab
            releasedView = tab.webView
            manager.close(tab.id)
        }
        try await wait("tab released") { released == nil }
        try await wait("web view released") { releasedView == nil }
    }

    @Test func sleptTabReleasesItsOldWebView() async throws {
        let server = try await LocalTestServer()
        weak var releasedView: WKWebView?
        let tab = try await openBackgroundPage(server)
        releasedView = tab.webView
        #expect(manager.sleep(tab.id))
        try await wait("old web view released") { releasedView == nil }
    }

    private func script(_ tab: Tab, _ source: String) async throws -> Any? {
        try await tab.webView.callAsyncJavaScript(source, contentWorld: .page)
    }

    @Test func pageAlertReachesTheUser() async throws {
        let server = try await LocalTestServer()
        let dialogs = FakeDialogs()
        manager.dialogs = dialogs
        let tab = manager.newTab(url: server.baseURL.appending(path: "page"))
        try await wait("page") { tab.title != nil && !tab.isLoading }

        _ = try await script(tab, "alert('Saved'); return 1")
        #expect(dialogs.alerts == ["Saved"])
    }

    @Test func pageConfirmReturnsTheAnswer() async throws {
        let server = try await LocalTestServer()
        let dialogs = FakeDialogs()
        manager.dialogs = dialogs
        let tab = manager.newTab(url: server.baseURL.appending(path: "page"))
        try await wait("page") { tab.title != nil && !tab.isLoading }

        #expect(try await script(tab, "return confirm('Delete?')") as? Bool == false)
        dialogs.confirmAnswer = true
        #expect(try await script(tab, "return confirm('Delete?')") as? Bool == true)
    }

    @Test func pagePromptReturnsTheText() async throws {
        let server = try await LocalTestServer()
        let dialogs = FakeDialogs()
        dialogs.promptAnswer = "Ada"
        manager.dialogs = dialogs
        let tab = manager.newTab(url: server.baseURL.appending(path: "page"))
        try await wait("page") { tab.title != nil && !tab.isLoading }

        #expect(try await script(tab, "return prompt('Name?', 'x')") as? String == "Ada")
    }

    @Test func protectedPageAsksForCredentialsAndLoads() async throws {
        let server = try await LocalTestServer()
        let dialogs = FakeDialogs()
        dialogs.credential = URLCredential(user: "ada", password: "secret", persistence: .forSession)
        manager.dialogs = dialogs

        let tab = manager.newTab(url: server.baseURL.appending(path: "auth"))
        try await wait("page behind login") { tab.title == "Test Page" }
        #expect(dialogs.authRequests == ["Test Realm"])
    }

    @Test func cancellingLoginDoesNotLoadThePage() async throws {
        let server = try await LocalTestServer()
        let dialogs = FakeDialogs()
        manager.dialogs = dialogs

        let tab = manager.newTab(url: server.baseURL.appending(path: "auth"))
        try await wait("asked") { !dialogs.authRequests.isEmpty }
        try await Task.sleep(for: .milliseconds(300))
        #expect(tab.title != "Test Page")
        #expect(dialogs.authRequests.count == 1, "A refused login must not ask again in a loop")
    }

    @Test func pageCannotPutDataAddressInTheWindow() async throws {
        let server = try await LocalTestServer()
        let page = server.baseURL.appending(path: "page")
        let tab = manager.newTab(url: page)
        try await wait("page") { tab.title != nil && !tab.isLoading }

        _ = try await script(tab, "location.href = 'data:text/html,<title>Fake Bank</title>'; return 1")
        try await Task.sleep(for: .milliseconds(300))
        #expect(tab.title != "Fake Bank")
        #expect(tab.url == page)
    }

    private func makeLoginManager(store: InMemoryCredentialStore) -> TabManager {
        TabManager(factory: WebViewFactory(profileID: UUID()), downloads: downloads, credentials: store)
    }

    private func loadedTab(_ manager: TabManager, _ url: URL) async throws -> Tab {
        let tab = manager.newTab(url: url)
        try await wait("page loaded") { tab.title == "Login" && !tab.isLoading }
        return tab
    }

    @Test func submittedLoginOffersToSave() async throws {
        let server = try await LocalTestServer()
        let store = InMemoryCredentialStore()
        let manager = makeLoginManager(store: store)
        let tab = try await loadedTab(manager, server.baseURL.appending(path: "login"))

        _ = try await tab.webView.evaluateJavaScript("""
        document.getElementById('u').value = 'ada';
        document.getElementById('p').value = 'secret';
        document.getElementById('f').requestSubmit(); 1
        """)

        try await wait("save prompt") { tab.loginPrompt != nil }
        #expect(tab.loginPrompt == .save(
            SavedLogin(origin: LoginOrigin.make(from: server.baseURL)!, username: "ada"),
            password: "secret",
            isUpdate: false
        ))
        #expect(await store.saved.isEmpty, "Nothing is stored before the user accepts")

        await manager.acceptLoginPrompt(on: tab)
        #expect(tab.loginPrompt == nil)
        #expect(await store.saved.values.contains("secret"))
    }

    @Test func unchangedPasswordDoesNotAskAgain() async throws {
        let server = try await LocalTestServer()
        let origin = LoginOrigin.make(from: server.baseURL)!
        let store = InMemoryCredentialStore()
        try await store.save(SavedLogin(origin: origin, username: "ada"), password: "secret")
        let manager = makeLoginManager(store: store)
        let tab = try await loadedTab(manager, server.baseURL.appending(path: "login"))
        try await wait("fill prompt") { tab.loginPrompt != nil }
        manager.dismissLoginPrompt(on: tab)

        _ = try await tab.webView.evaluateJavaScript("""
        document.getElementById('u').value = 'ada';
        document.getElementById('p').value = 'secret';
        document.getElementById('f').requestSubmit(); 1
        """)
        try await Task.sleep(for: .milliseconds(300))
        #expect(tab.loginPrompt == nil)
    }

    @Test func savedLoginIsOfferedButFillsOnlyAfterAcceptance() async throws {
        let server = try await LocalTestServer()
        let login = SavedLogin(origin: LoginOrigin.make(from: server.baseURL)!, username: "ada")
        let store = InMemoryCredentialStore()
        try await store.save(login, password: "secret")
        let manager = makeLoginManager(store: store)
        let tab = try await loadedTab(manager, server.baseURL.appending(path: "login"))

        try await wait("fill prompt") { tab.loginPrompt == .fill([login]) }
        #expect(try await tab.webView.evaluateJavaScript("document.getElementById('p').value") as? String == "")

        await manager.fill(login, on: tab)
        #expect(try await tab.webView.evaluateJavaScript("document.getElementById('u').value") as? String == "ada")
        #expect(try await tab.webView.evaluateJavaScript("document.getElementById('p').value") as? String == "secret")
        #expect(tab.loginPrompt == nil)
    }

    @Test func pageScriptsCannotReachTheLoginBridge() async throws {
        let server = try await LocalTestServer()
        let manager = makeLoginManager(store: InMemoryCredentialStore())
        let tab = try await loadedTab(manager, server.baseURL.appending(path: "login"))

        let bridge = try await tab.webView.evaluateJavaScript("""
        typeof (window.webkit && webkit.messageHandlers && webkit.messageHandlers.kaffinLogin)
        """) as? String
        #expect(bridge == "undefined")
    }

    @Test func loginInFrameIsIgnored() async throws {
        let server = try await LocalTestServer()
        let store = InMemoryCredentialStore()
        try await store.save(
            SavedLogin(origin: LoginOrigin.make(from: server.baseURL)!, username: "ada"),
            password: "secret"
        )
        let manager = makeLoginManager(store: store)
        let tab = manager.newTab(url: server.baseURL.appending(path: "framed"))
        try await wait("page loaded") { tab.title == "Framed" && !tab.isLoading }
        try await Task.sleep(for: .milliseconds(300))
        #expect(tab.loginPrompt == nil)
    }

    @Test func tabsWithoutCredentialStoreHaveNoBridge() async throws {
        let server = try await LocalTestServer()
        let tab = try await loadedTab(manager, server.baseURL.appending(path: "login"))
        #expect(tab.webView.configuration.userContentController.userScripts.isEmpty)
    }
}

actor InMemoryCredentialStore: CredentialStoring {
    private(set) var saved: [SavedLogin: String] = [:]

    func logins(for origin: String?) -> [SavedLogin] {
        saved.keys.filter { origin == nil || $0.origin == origin }
    }

    func password(for login: SavedLogin) -> String? {
        saved[login]
    }

    func save(_ login: SavedLogin, password: String) {
        saved[login] = password
    }

    func delete(_ login: SavedLogin) {
        saved[login] = nil
    }
}
