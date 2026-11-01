import AppKit
import BrowserCore
import LocalAuthentication
import SwiftUI

public enum SettingsPane: Hashable, Sendable {
    case general
    case passwords
    case performance
    case sitePermissions
    case importData
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
    let onSetDefault: () -> Void

    public init(
        navigation: SettingsNavigation,
        search: SearchSettings,
        accent: AccentSettings,
        performance: PerformanceSettings,
        sitePermissions: SitePermissionsModel,
        passwords: PasswordsModel,
        browserImport: BrowserImportModel,
        onSetDefault: @escaping () -> Void
    ) {
        self.navigation = navigation
        self.search = search
        self.accent = accent
        self.performance = performance
        self.sitePermissions = sitePermissions
        self.passwords = passwords
        self.browserImport = browserImport
        self.onSetDefault = onSetDefault
    }

    private static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""

    private static let panes: [(pane: SettingsPane, key: String, symbol: String)] = [
        (.general, "settings.general", "gearshape"),
        (.passwords, "settings.passwords", "key"),
        (.performance, "settings.performance", "gauge.with.dots.needle.67percent"),
        (.sitePermissions, "settings.sitePermissions", "lock.shield"),
        (.importData, "settings.import", "square.and.arrow.down"),
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
            selectedPane
                .padding(32)
                .frame(maxWidth: 760, maxHeight: .infinity, alignment: .topLeading)
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
        case .general: GeneralSettingsView(search: search, accent: accent, onSetDefault: onSetDefault)
        case .passwords: PasswordsSettingsView(model: passwords)
        case .performance: PerformanceSettingsView(settings: performance)
        case .sitePermissions: SitePermissionsSettingsView(model: sitePermissions)
        case .importData: ImportSettingsView(model: browserImport)
        }
    }
}

private struct GeneralSettingsView: View {
    let search: SearchSettings
    let accent: AccentSettings
    let onSetDefault: () -> Void

    @State private var template = ""
    @State private var isTemplateInvalid = false

    var body: some View {
        Form {
            Picker(L10n.string("settings.searchEngine"), selection: selection) {
                ForEach(SearchEngine.builtIn, id: \.name) { Text($0.name).tag($0.name) }
                Text(L10n.string("settings.customEngine")).tag(SearchSettings.customName)
            }
            if search.engine.name == SearchSettings.customName || !template.isEmpty {
                TextField(L10n.string("settings.customTemplate"), text: $template)
                    .onSubmit { isTemplateInvalid = !search.setCustom(template: template) }
                if isTemplateInvalid {
                    Text(L10n.string("settings.customInvalid")).foregroundStyle(.secondary)
                }
            }
            HStack {
                ColorPicker(L10n.string("settings.accent"), selection: accentColor, supportsOpacity: false)
                if accent.color != nil {
                    Button(L10n.string("settings.accentReset")) { accent.color = nil }
                }
            }
            Button(L10n.string("menu.setDefault"), action: onSetDefault)
        }
        .onAppear {
            if search.engine.name == SearchSettings.customName { template = search.engine.queryTemplate }
        }
    }

    private var accentColor: Binding<Color> {
        Binding {
            accent.color?.swiftUIColor ?? .accentColor
        } set: { color in
            if let rgb = NSColor(color).usingColorSpace(.sRGB) {
                accent.color = AccentColor(
                    red: Double(rgb.redComponent),
                    green: Double(rgb.greenComponent),
                    blue: Double(rgb.blueComponent)
                )
            }
        }
    }

    private var selection: Binding<String> {
        Binding {
            search.engine.name
        } set: { name in
            if let engine = SearchEngine.builtIn.first(where: { $0.name == name }) {
                search.select(engine)
                template = ""
            } else if template.isEmpty {
                template = "https://"
            }
        }
    }
}

private struct PerformanceSettingsView: View {
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

private struct SitePermissionsSettingsView: View {
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

private struct PasswordsSettingsView: View {
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
