import BrowserCore
import Extensions
import Foundation
import Testing
@testable import Tabs

/// Installs a real Manifest V3 extension into real WebKit, against a local server.
@MainActor
@Suite(.serialized)
struct ExtensionHostTests {
    private let root: URL
    private let profile = UUID()

    init() throws {
        root = FileManager.default.temporaryDirectory.appending(path: "kaffin ext \(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    private func wait(_ what: Comment, until condition: () async -> Bool) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(await condition(), what)
    }

    /// Replies with what the background worker can see, which only works if the tab APIs are connected.
    private func makeExtension() throws -> URL {
        let folder = root.appending(path: "source")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try #"""
        {"manifest_version":3,"name":"Probe","version":"1.2","description":"Test",
         "background":{"service_worker":"bg.js"},
         "permissions":["storage","tabs","scripting"],
         "host_permissions":["http://127.0.0.1/*"],
         "action":{"default_title":"Probe"},
         "content_scripts":[{"matches":["http://127.0.0.1/*"],"js":["cs.js"]}]}
        """#.write(to: folder.appending(path: "manifest.json"), atomically: true, encoding: .utf8)
        try #"""
        chrome.runtime.onMessage.addListener((message, sender, reply) => {
          (async () => {
            if (message.open) { await chrome.tabs.create({ url: message.open, active: false }); reply({ opened: true }); return; }
            await chrome.storage.local.set({ visits: 1 });
            const stored = await chrome.storage.local.get('visits');
            const tabs = await chrome.tabs.query({ currentWindow: true });
            reply({ stored: stored.visits, tabs: tabs.length, title: sender.tab?.title, active: sender.tab?.active });
          })();
          return true;
        });
        """#.write(to: folder.appending(path: "bg.js"), atomically: true, encoding: .utf8)
        try #"""
        document.documentElement.dataset.probe = 'ran';
        document.addEventListener('probe-open', () => {
          chrome.runtime.sendMessage({ open: document.documentElement.dataset.open });
        });
        addEventListener('load', () => {
          chrome.runtime.sendMessage({ hello: 1 }).then((reply) => {
            document.documentElement.dataset.reply = JSON.stringify(reply);
          }).catch((error) => { document.documentElement.dataset.reply = 'ERROR ' + error; });
        });
        """#.write(to: folder.appending(path: "cs.js"), atomically: true, encoding: .utf8)
        return folder
    }

    private func makeHost(approve: Bool = true) -> (ExtensionHost, WebViewFactory) {
        let factory = WebViewFactory(profileID: profile)
        let host = ExtensionHost(
            profileID: profile,
            directory: root.appending(path: "installed"),
            factory: factory,
            approve: { _ in approve }
        )
        return (host, factory)
    }

    private func dataset(_ tab: Tab, _ key: String) async -> String? {
        try? await tab.webView.evaluateJavaScript("document.documentElement.dataset.\(key)") as? String
    }

    @Test func contentScriptReachesWorkerThroughTabAPIs() async throws {
        let server = try await LocalTestServer()
        let (host, factory) = makeHost()
        let manager = TabManager(factory: factory)
        host.register(manager, window: nil)
        try await host.install(from: makeExtension())

        manager.newTab()
        let tab = manager.newTab(url: server.baseURL.appending(path: "page"))
        try await wait("reply") { await dataset(tab, "reply") != nil }

        let reply = await dataset(tab, "reply")
        #expect(reply?.contains(#""stored":1"#) == true, "\(reply ?? "nil")")
        #expect(reply?.contains(#""tabs":2"#) == true, "\(reply ?? "nil")")
        #expect(reply?.contains(#""active":true"#) == true, "\(reply ?? "nil")")
        #expect(host.model.entries.first?.name == "Probe")
        #expect(host.model.entries.first?.version == "1.2")
    }

    @Test func extensionCanOpenTabs() async throws {
        let server = try await LocalTestServer()
        let (host, factory) = makeHost()
        let manager = TabManager(factory: factory)
        host.register(manager, window: nil)
        try await host.install(from: makeExtension())
        let tab = manager.newTab(url: server.baseURL.appending(path: "page"))
        try await wait("page") { await dataset(tab, "reply") != nil }

        let target = server.baseURL.appending(path: "iconpage").absoluteString
        _ = try await tab.webView.evaluateJavaScript("""
        document.documentElement.dataset.open = '\(target)';
        document.dispatchEvent(new Event('probe-open')); 1
        """)
        try await wait("second tab") { manager.tabs.count == 2 }
        #expect(manager.selectedTabID == tab.id, "active:false must not steal focus")
    }

    @Test func refusedInstallLeavesNothing() async throws {
        let (host, _) = makeHost(approve: false)
        await #expect(throws: ExtensionHost.InstallError.declined) {
            try await host.install(from: try makeExtension())
        }
        #expect(host.model.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: root.appending(path: "installed/index.json").path(percentEncoded: false)))
    }

    @Test func folderWithoutManifestIsRefused() async throws {
        let (host, _) = makeHost()
        let empty = root.appending(path: "empty")
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        await #expect(throws: (any Error).self) { try await host.install(from: empty) }
        #expect(host.model.entries.isEmpty)
    }

    @Test func disabledExtensionStopsRunningAndCanReturn() async throws {
        let server = try await LocalTestServer()
        let (host, factory) = makeHost()
        let manager = TabManager(factory: factory)
        host.register(manager, window: nil)
        try await host.install(from: makeExtension())
        let id = try #require(host.model.entries.first?.id)

        host.setEnabled(id, false)
        #expect(host.model.entries.first?.isEnabled == false)
        let off = manager.newTab(url: server.baseURL.appending(path: "page"))
        try await wait("page") { off.title != nil && !off.isLoading }
        #expect(await dataset(off, "probe") == nil)

        host.setEnabled(id, true)
        let on = manager.newTab(url: server.baseURL.appending(path: "page"))
        try await wait("content script") { await dataset(on, "probe") == "ran" }
    }

    @Test func installedExtensionAndItsGrantsSurviveRestart() async throws {
        let server = try await LocalTestServer()
        do {
            let (host, _) = makeHost()
            try await host.install(from: makeExtension())
        }
        let (host, factory) = makeHost(approve: false)
        await host.loadInstalled()
        #expect(host.model.entries.map(\.name) == ["Probe"])

        let manager = TabManager(factory: factory)
        host.register(manager, window: nil)
        let tab = manager.newTab(url: server.baseURL.appending(path: "page"))
        try await wait("content script") { await dataset(tab, "probe") == "ran" }
    }

    @Test func storeInstallIsRememberedAcrossRestart() async throws {
        let storeID = "ddkjiahejlhfcafbddmgiahcphecmpfh"
        do {
            let (host, _) = makeHost()
            try await host.install(from: makeExtension(), storeID: storeID)
            #expect(host.model.isInstalled(storeID: storeID))
        }
        let (host, _) = makeHost()
        await host.loadInstalled()
        #expect(host.model.isInstalled(storeID: storeID))
        #expect(!host.model.isInstalled(storeID: "aaaabbbbccccddddeeeeffffgggghhhh"))
    }

    @Test func removalDeletesItsFiles() async throws {
        let (host, _) = makeHost()
        try await host.install(from: makeExtension())
        let id = try #require(host.model.entries.first?.id)
        let folder = root.appending(path: "installed/\(id)")
        #expect(FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)))

        await host.remove(id)
        #expect(host.model.entries.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: folder.path(percentEncoded: false)))
    }

    @Test func zipPackageInstalls() async throws {
        let source = try makeExtension()
        let zip = root.appending(path: "probe.zip")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/zip")
        process.currentDirectoryURL = source
        process.arguments = ["-q", "-r", zip.path(percentEncoded: false), "."]
        try process.run()
        process.waitUntilExit()

        let (host, _) = makeHost()
        try await host.install(from: zip)
        #expect(host.model.entries.first?.name == "Probe")
    }

    @Test func privateFactoryCarriesNoExtensions() async throws {
        let server = try await LocalTestServer()
        let (host, _) = makeHost()
        try await host.install(from: makeExtension())

        let manager = TabManager(factory: .privateSession())
        let tab = manager.newTab(url: server.baseURL.appending(path: "page"))
        try await wait("page") { tab.title != nil && !tab.isLoading }
        #expect(await dataset(tab, "probe") == nil)
    }
}
