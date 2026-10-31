import AppKit
import BrowserCore
import Foundation
import OSLog
import Tabs
import WebKit

/// Everything WebKit needs from a browser to run extensions. The extension runtime itself is WebKit's.
@MainActor
public final class ExtensionHost: NSObject, WKWebExtensionControllerDelegate, ExtensionCommands {
    private static let logger = Logger(subsystem: "com.kaffin.browser", category: "Extensions")
    private static let maximumPackageSize = 200_000_000

    public typealias InstallError = ExtensionInstallError

    /// What the user is asked to allow.
    public struct Approval: Sendable {
        public let name: String
        public let permissions: [String]
        public let sites: [String]
    }

    private struct Record: Codable {
        let id: String
        let package: String
        var isEnabled: Bool
        var permissions: [String]
        var sites: [String]
        var storeID: String?
    }

    public let model = ExtensionsModel()
    private let controller: WKWebExtensionController
    private let directory: URL
    private let approve: @MainActor (Approval) -> Bool
    private var records: [Record] = []
    private var contexts: [String: WKWebExtensionContext] = [:]
    private var extensions: [String: WKWebExtension] = [:]
    private var windows: [ExtensionWindow] = []
    private var tabAdapters: [Tabs.Tab.ID: ExtensionTab] = [:]

    public init(
        profileID: UUID,
        directory: URL,
        factory: WebViewFactory,
        approve: @escaping @MainActor (Approval) -> Bool
    ) {
        let configuration = WKWebExtensionController.Configuration(identifier: profileID)
        configuration.defaultWebsiteDataStore = factory.dataStore
        controller = WKWebExtensionController(configuration: configuration)
        self.directory = directory
        self.approve = approve
        super.init()
        controller.delegate = self
        model.commands = self
        factory.extensionController = controller
    }

    // MARK: Windows and tabs

    public func register(_ manager: TabManager, window: NSWindow?) {
        let extensionWindow = ExtensionWindow(manager: manager, window: window, host: self)
        windows.append(extensionWindow)
        controller.didOpenWindow(extensionWindow)
        manager.onTabEvent = { [weak self] in self?.handle($0) }
        manager.tabs.forEach { controller.didOpenTab(adapter(for: $0)) }
    }

    public func unregister(_ manager: TabManager) {
        guard let window = windows.first(where: { $0.manager === manager }) else { return }
        manager.tabs.forEach {
            if let adapter = tabAdapters.removeValue(forKey: $0.id) {
                controller.didCloseTab(adapter, windowIsClosing: true)
            }
        }
        controller.didCloseWindow(window)
        windows.removeAll { $0 === window }
    }

    func adapter(for tab: Tabs.Tab) -> ExtensionTab {
        if let adapter = tabAdapters[tab.id] { return adapter }
        let adapter = ExtensionTab(tab: tab, host: self)
        tabAdapters[tab.id] = adapter
        return adapter
    }

    func window(containing tab: Tabs.Tab) -> ExtensionWindow? {
        windows.first { $0.manager.tabs.contains { $0 === tab } }
    }

    private func handle(_ event: TabEvent) {
        switch event {
        case .opened(let tab):
            controller.didOpenTab(adapter(for: tab))
        case .closed(let tab):
            if let adapter = tabAdapters.removeValue(forKey: tab.id) {
                controller.didCloseTab(adapter, windowIsClosing: false)
            }
        case .selected(let tab, let previous):
            controller.didActivateTab(adapter(for: tab), previousActiveTab: previous.map(adapter))
        case .moved(let tab, let index):
            controller.didMoveTab(adapter(for: tab), from: index, in: window(containing: tab))
        case .changed(let tab):
            controller.didChangeTabProperties([.URL, .title, .loading, .pinned, .muted], for: adapter(for: tab))
        }
    }

    // MARK: Installing

    /// Takes a folder, or a `.zip` or `.crx` file. Nothing stays behind unless the user approves.
    public func install(from source: URL) async throws {
        try await install(from: source, storeID: nil)
    }

    public func install(from source: URL, storeID: String?) async throws {
        let id = UUID().uuidString
        let folder = directory.appending(path: id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        do {
            let package = try copyPackage(from: source, into: folder)
            let webExtension: WKWebExtension
            do {
                webExtension = try await WKWebExtension(resourceBaseURL: folder.appending(path: package))
            } catch {
                throw InstallError.notAnExtension
            }
            let permissions = webExtension.requestedPermissions.map(\.rawValue).sorted()
            let sites = webExtension.allRequestedMatchPatterns.map(\.string).sorted()
            let approval = Approval(name: webExtension.displayName ?? "", permissions: permissions, sites: sites)
            guard approve(approval) else { throw InstallError.declined }

            let record = Record(
                id: id,
                package: package,
                isEnabled: true,
                permissions: permissions,
                sites: sites,
                storeID: storeID
            )
            records.append(record)
            extensions[id] = webExtension
            try load(record, webExtension)
            try saveIndex()
            refreshModel()
        } catch {
            records.removeAll { $0.id == id }
            extensions[id] = nil
            try? FileManager.default.removeItem(at: folder)
            throw error
        }
    }

    public func installFromStore(id: String) async throws {
        let (file, response) = try await URLSession.shared.download(from: ChromeWebStore.packageURL(for: id))
        defer { try? FileManager.default.removeItem(at: file) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw InstallError.notAnExtension }
        try await install(from: file, storeID: id)
    }

    private func copyPackage(from source: URL, into folder: URL) throws -> String {
        let isDirectory = try source.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        if isDirectory {
            try FileManager.default.copyItem(at: source, to: folder.appending(path: "package"))
            return "package"
        }
        guard try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0 <= Self.maximumPackageSize else {
            throw InstallError.tooLarge
        }
        guard let archive = CRXFile.zipArchive(from: try Data(contentsOf: source)) else {
            throw InstallError.notAnExtension
        }
        try archive.write(to: folder.appending(path: "package.zip"))
        return "package.zip"
    }

    private func load(_ record: Record, _ webExtension: WKWebExtension) throws {
        let context = WKWebExtensionContext(for: webExtension)
        // A fixed identifier keeps the extension's storage across launches.
        context.uniqueIdentifier = record.id
        for permission in record.permissions {
            context.setPermissionStatus(.grantedExplicitly, for: WKWebExtension.Permission(rawValue: permission))
        }
        for site in record.sites {
            if let pattern = try? WKWebExtension.MatchPattern(string: site) {
                context.setPermissionStatus(.grantedExplicitly, for: pattern)
            }
        }
        try controller.load(context)
        contexts[record.id] = context
    }

    /// A broken extension stays listed with its error, so the user can see it and remove it.
    public func loadInstalled() async {
        let index = directory.appending(path: "index.json")
        guard let data = try? Data(contentsOf: index),
              let stored = try? JSONDecoder().decode([Record].self, from: data) else { return }
        records = stored
        for record in stored {
            do {
                let webExtension = try await WKWebExtension(
                    resourceBaseURL: directory.appending(path: "\(record.id)/\(record.package)")
                )
                extensions[record.id] = webExtension
                if record.isEnabled { try load(record, webExtension) }
            } catch {
                Self.logger.error("Could not load extension: \(error.localizedDescription, privacy: .public)")
            }
        }
        refreshModel()
    }

    private func saveIndex() throws {
        try JSONEncoder().encode(records).write(to: directory.appending(path: "index.json"), options: .atomic)
    }

    private func refreshModel() {
        model.entries = records.map { record in
            let webExtension = extensions[record.id]
            return ExtensionEntry(
                id: record.id,
                name: webExtension?.displayName ?? record.id,
                version: webExtension?.displayVersion ?? "",
                isEnabled: record.isEnabled,
                problems: (webExtension?.errors ?? []).map(\.localizedDescription)
                    + (contexts[record.id]?.errors ?? []).map(\.localizedDescription),
                icon: webExtension?.icon(for: NSSize(width: 32, height: 32)),
                storeID: record.storeID
            )
        }
    }

    // MARK: ExtensionCommands

    public func setEnabled(_ id: String, _ isEnabled: Bool) {
        guard let index = records.firstIndex(where: { $0.id == id }), records[index].isEnabled != isEnabled else { return }
        records[index].isEnabled = isEnabled
        if isEnabled, let webExtension = extensions[id] {
            try? load(records[index], webExtension)
        } else if let context = contexts.removeValue(forKey: id) {
            try? controller.unload(context)
        }
        try? saveIndex()
        refreshModel()
    }

    public func remove(_ id: String) async {
        if let context = contexts.removeValue(forKey: id) {
            await removeStoredData(of: context)
            try? controller.unload(context)
        }
        records.removeAll { $0.id == id }
        extensions[id] = nil
        try? FileManager.default.removeItem(at: directory.appending(path: id))
        try? saveIndex()
        refreshModel()
    }

    /// Called before a profile is deleted, because WebKit keeps this data outside the profile's folder.
    public func removeAllData() async {
        for context in contexts.values { await removeStoredData(of: context) }
    }

    private func removeStoredData(of context: WKWebExtensionContext) async {
        let types = WKWebExtensionController.allExtensionDataTypes
        let records = await controller.dataRecords(ofTypes: types).filter { $0.uniqueIdentifier == context.uniqueIdentifier }
        await controller.removeData(ofTypes: types, from: records)
    }

    public func performAction(_ id: String) {
        guard let context = contexts[id] else { return }
        let active = windows.last?.manager.selectedTab.map(adapter)
        context.performAction(for: active)
    }

    // MARK: WKWebExtensionControllerDelegate

    public func webExtensionController(
        _ controller: WKWebExtensionController,
        openWindowsFor extensionContext: WKWebExtensionContext
    ) -> [any WKWebExtensionWindow] {
        windows
    }

    public func webExtensionController(
        _ controller: WKWebExtensionController,
        focusedWindowFor extensionContext: WKWebExtensionContext
    ) -> (any WKWebExtensionWindow)? {
        windows.first { $0.window?.isKeyWindow == true } ?? windows.last
    }

    public func webExtensionController(
        _ controller: WKWebExtensionController,
        openNewTabUsing configuration: WKWebExtension.TabConfiguration,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any WKWebExtensionTab)?, (any Error)?) -> Void
    ) {
        let target = (configuration.window as? ExtensionWindow) ?? windows.last
        guard let manager = target?.manager else {
            completionHandler(nil, InstallError.notAnExtension)
            return
        }
        let tab = manager.newTab(url: configuration.url, select: configuration.shouldBeActive)
        if configuration.shouldBePinned { manager.togglePin(tab.id) }
        completionHandler(adapter(for: tab), nil)
    }

    public func webExtensionController(
        _ controller: WKWebExtensionController,
        openOptionsPageFor extensionContext: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        if let url = extensionContext.optionsPageURL { windows.last?.manager.newTab(url: url) }
        completionHandler(nil)
    }

    public func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissions permissions: Set<WKWebExtension.Permission>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.Permission>, Date?) -> Void
    ) {
        let approval = Approval(
            name: extensionContext.webExtension.displayName ?? "",
            permissions: permissions.map(\.rawValue).sorted(),
            sites: []
        )
        guard approve(approval) else {
            completionHandler([], nil)
            return
        }
        remember(extensionContext) { $0.permissions = Array(Set($0.permissions + approval.permissions)) }
        completionHandler(permissions, nil)
    }

    public func webExtensionController(
        _ controller: WKWebExtensionController,
        promptForPermissionMatchPatterns matchPatterns: Set<WKWebExtension.MatchPattern>,
        in tab: (any WKWebExtensionTab)?,
        for extensionContext: WKWebExtensionContext,
        completionHandler: @escaping (Set<WKWebExtension.MatchPattern>, Date?) -> Void
    ) {
        let approval = Approval(
            name: extensionContext.webExtension.displayName ?? "",
            permissions: [],
            sites: matchPatterns.map(\.string).sorted()
        )
        guard approve(approval) else {
            completionHandler([], nil)
            return
        }
        remember(extensionContext) { $0.sites = Array(Set($0.sites + approval.sites)) }
        completionHandler(matchPatterns, nil)
    }

    private func remember(_ context: WKWebExtensionContext, change: (inout Record) -> Void) {
        guard let index = records.firstIndex(where: { $0.id == context.uniqueIdentifier }) else { return }
        change(&records[index])
        try? saveIndex()
    }

    public func webExtensionController(
        _ controller: WKWebExtensionController,
        presentActionPopup action: WKWebExtension.Action,
        for context: WKWebExtensionContext,
        completionHandler: @escaping ((any Error)?) -> Void
    ) {
        guard let popover = action.popupPopover,
              let view = (windows.first { $0.window?.isKeyWindow == true } ?? windows.last)?.window?.contentView else {
            completionHandler(InstallError.notAnExtension)
            return
        }
        // Under the toolbar's extensions button, at the right end of the window.
        let anchor = NSRect(x: view.bounds.maxX - 110, y: view.bounds.maxY - 84, width: 24, height: 1)
        popover.show(relativeTo: anchor, of: view, preferredEdge: .minY)
        completionHandler(nil)
    }
}
