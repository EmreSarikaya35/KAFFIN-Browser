import BrowserCore
import Foundation
import Testing
@testable import Tabs

/// Runs real WebKit against a local server, with no window. Proves the delegates are really called.
@MainActor
@Suite(.serialized)
struct WebKitIntegrationTests {
    private let folder: URL
    private let downloads: DownloadManager
    private let manager: TabManager

    init() throws {
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
