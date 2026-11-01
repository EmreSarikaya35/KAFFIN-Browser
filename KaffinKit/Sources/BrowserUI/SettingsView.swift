import AppKit
import BrowserCore
import LocalAuthentication
import SwiftUI

public enum SettingsPane: Hashable, Sendable {
    case general
    case appearance
    case search
    case passwords
    case privacy
    case sitePermissions
    case performance
    case downloads
    case accessibility
    case importData
    case reset
    case about
}

@MainActor
@Observable
public final class SettingsNavigation {
    public var pane = SettingsPane.general
    public init() {}
}

public struct SettingsView: View {
    @Bindable var navigation: SettingsNavigation
    let search: SearchSettings
    let accent: AccentSettings
    let performance: PerformanceSettings
    let sitePermissions: SitePermissionsModel
    let passwords: PasswordsModel
    let browserImport: BrowserImportModel
    let bookmarks: BookmarksModel
    let onClearData: (ClearDataRequest) async -> Void
    let onSetDefault: () -> Void

    public init(
        navigation: SettingsNavigation,
        search: SearchSettings,
        accent: AccentSettings,
        performance: PerformanceSettings,
        sitePermissions: SitePermissionsModel,
        passwords: PasswordsModel,
        browserImport: BrowserImportModel,
        bookmarks: BookmarksModel,
        onClearData: @escaping (ClearDataRequest) async -> Void,
        onSetDefault: @escaping () -> Void
    ) {
        self.navigation = navigation
        self.search = search
        self.accent = accent
        self.performance = performance
        self.sitePermissions = sitePermissions
        self.passwords = passwords
        self.browserImport = browserImport
        self.bookmarks = bookmarks
        self.onClearData = onClearData
        self.onSetDefault = onSetDefault
    }

    private static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""

    private static let panes: [(pane: SettingsPane, key: String, symbol: String)] = [
        (.general, "settings.general", "gearshape"),
        (.appearance, "settings.appearance", "paintbrush"),
        (.search, "settings.search", "magnifyingglass"),
        (.passwords, "settings.passwords", "key"),
        (.privacy, "settings.privacy", "hand.raised"),
        (.sitePermissions, "settings.sitePermissions", "lock.shield"),
        (.performance, "settings.performance", "gauge.with.dots.needle.67percent"),
        (.downloads, "settings.downloads", "arrow.down.circle"),
        (.accessibility, "settings.accessibility", "accessibility"),
        (.importData, "settings.import", "square.and.arrow.down"),
        (.reset, "settings.reset", "arrow.counterclockwise"),
        (.about, "settings.about", "info.circle"),
    ]

    public var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.string("settings.title"))
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 10)
                    .padding(.bottom, 12)
                ForEach(Self.panes, id: \.pane) { sidebarRow($0.pane, key: $0.key, symbol: $0.symbol) }
                Spacer()
                Text("KAFFIN \(Self.version)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .padding(.horizontal, 10)
            }
            .padding(20)
            .frame(width: 240)
            .frame(maxHeight: .infinity)
            .background(ChromePalette.toolbar)
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                Text(L10n.string(Self.panes.first { $0.pane == navigation.pane }?.key ?? "settings.title"))
                    .font(.title2.weight(.semibold))
                    .padding(.horizontal, 20)
                selectedPane.formStyle(.grouped)
            }
            .padding(.vertical, 24)
            .padding(.horizontal, 12)
            .frame(maxWidth: 780, maxHeight: .infinity, alignment: .topLeading)
            .frame(maxWidth: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private func sidebarRow(_ pane: SettingsPane, key: String, symbol: String) -> some View {
        Button {
            navigation.pane = pane
        } label: {
            Label(L10n.string(key), systemImage: symbol)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .frame(height: 32)
                .contentShape(Rectangle())
                .background(navigation.pane == pane ? ChromePalette.field : .clear, in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(navigation.pane == pane ? .isSelected : [])
    }

    @ViewBuilder private var selectedPane: some View {
        switch navigation.pane {
        case .general: GeneralSettingsView(onSetDefault: onSetDefault)
        case .appearance: AppearanceSettingsView(accent: accent, bookmarks: bookmarks)
        case .search: SearchSettingsView(search: search)
        case .passwords: PasswordsPaneView(model: passwords)
        case .privacy: PrivacySettingsView(onClearData: onClearData)
        case .sitePermissions: SitePermissionsSettingsView(model: sitePermissions)
        case .performance: PerformanceSettingsView(settings: performance)
        case .downloads: DownloadsSettingsView()
        case .accessibility: AccessibilitySettingsView()
        case .importData: ImportSettingsView(model: browserImport)
        case .reset: ResetSettingsView()
        case .about: AboutSettingsView()
        }
    }
}

struct PerformanceSettingsView: View {
    @Bindable var settings: PerformanceSettings
    @State private var excludedText = ""
    @State private var memory: Int64?

    var body: some View {
        Form {
            Picker(L10n.string("performance.profile"), selection: profile) {
                ForEach(OptimizationProfile.allCases, id: \.self) {
                    Text(L10n.string("performance.\($0.rawValue)")).tag($0)
                }
            }
            Text(L10n.string("performance.\(settings.profile.rawValue)Detail"))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if settings.sleepsIdleTabs {
                Stepper(value: $settings.idleMinutes, in: 5...240, step: 5) {
                    Text(String(format: L10n.string("performance.idleMinutes"), settings.idleMinutes))
                }
            }
            if settings.sleepsUnderMemoryPressure {
                Toggle(L10n.string("performance.protectPinned"), isOn: $settings.protectsPinnedTabs)
                TextField(L10n.string("performance.excluded"), text: $excludedText, prompt: Text(L10n.string("performance.excludedHint")))
                    .onSubmit { settings.excludedSites = PerformanceSettings.sites(from: excludedText) }
            }
            if let memory {
                Text(String(format: L10n.string("performance.memory"), memory.formatted(.byteCount(style: .memory))))
                Text(L10n.string("performance.memoryNote")).font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            excludedText = settings.excludedSites.joined(separator: ", ")
            memory = ProcessMemory.footprint()
        }
    }

    /// Automatic sleeping can lose work on a page, so turning it on always takes a confirmation.
    private var profile: Binding<OptimizationProfile> {
        Binding {
            settings.profile
        } set: { profile in
            if profile == .aggressiveSaving, !Prompts.confirm(
                L10n.string("performance.confirmTitle"),
                detail: L10n.string("performance.confirmDetail"),
                action: L10n.string("performance.confirmAction")
            ) { return }
            settings.profile = profile
        }
    }
}

struct SitePermissionsSettingsView: View {
    let model: SitePermissionsModel

    var body: some View {
        Group {
            if model.entries.isEmpty {
                Text(L10n.string("permission.empty"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.entries) { entry in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(entry.site).lineLimit(1)
                            Text(L10n.string("permission.\(entry.kind.rawValue)")).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Picker(L10n.string("permission.\(entry.kind.rawValue)"), selection: Binding {
                            entry.isAllowed
                        } set: { allowed in
                            Task { await model.set(entry, allowed: allowed) }
                        }) {
                            Text(L10n.string("permission.allow")).tag(true)
                            Text(L10n.string("permission.block")).tag(false)
                        }
                        .labelsHidden()
                        .fixedSize()
                        Button(L10n.string("history.delete")) {
                            Task { await model.remove(entry) }
                        }
                    }
                }
            }
        }
        .task { await model.reload() }
    }
}

struct PasswordsSettingsView: View {
    let model: PasswordsModel
    @State private var revealed: [SavedLogin: String] = [:]

    var body: some View {
        Group {
            if model.logins.isEmpty {
                Text(L10n.string("password.empty"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.logins) { login in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(login.origin).lineLimit(1)
                            Text(login.username).foregroundStyle(.secondary).lineLimit(1)
                            if let password = revealed[login] {
                                Text(password).textSelection(.enabled).font(.system(.body, design: .monospaced))
                            }
                        }
                        Spacer()
                        Button(L10n.string(revealed[login] == nil ? "password.show" : "password.hide")) {
                            Task { await toggle(login) }
                        }
                        Button(L10n.string("history.delete")) {
                            Task { await model.delete(login) }
                        }
                    }
                }
            }
        }
        .task { await model.reload() }
        .onDisappear { revealed = [:] }
    }

    private func toggle(_ login: SavedLogin) async {
        if revealed[login] != nil {
            revealed[login] = nil
            return
        }
        guard await authenticate() else { return }
        revealed[login] = await model.password(for: login)
    }

    /// Asks for Touch ID or the Mac password, so an unattended Mac does not expose saved passwords.
    private func authenticate() async -> Bool {
        let reason = L10n.string("password.authReason")
        return (try? await LAContext().evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }
}
