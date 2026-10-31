import AppKit
import BrowserCore
import LocalAuthentication
import SwiftUI

public enum SettingsPane: Hashable, Sendable {
    case general
    case passwords
    case performance
    case extensions
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
    let extensions: ExtensionsModel
    let passwords: PasswordsModel
    let onSetDefault: () -> Void

    public init(
        navigation: SettingsNavigation,
        search: SearchSettings,
        accent: AccentSettings,
        performance: PerformanceSettings,
        extensions: ExtensionsModel,
        passwords: PasswordsModel,
        onSetDefault: @escaping () -> Void
    ) {
        self.navigation = navigation
        self.search = search
        self.accent = accent
        self.performance = performance
        self.extensions = extensions
        self.passwords = passwords
        self.onSetDefault = onSetDefault
    }

    public var body: some View {
        TabView(selection: $navigation.pane) {
            GeneralSettingsView(search: search, accent: accent, onSetDefault: onSetDefault)
                .tabItem { Text(L10n.string("settings.general")) }
                .tag(SettingsPane.general)
            PasswordsSettingsView(model: passwords)
                .tabItem { Text(L10n.string("settings.passwords")) }
                .tag(SettingsPane.passwords)
            PerformanceSettingsView(settings: performance)
                .tabItem { Text(L10n.string("settings.performance")) }
                .tag(SettingsPane.performance)
            ExtensionsSettingsView(model: extensions)
                .tabItem { Text(L10n.string("extensions.title")) }
                .tag(SettingsPane.extensions)
        }
        .padding(16)
        .frame(width: 560, height: 420)
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

private struct ExtensionsSettingsView: View {
    @Bindable var model: ExtensionsModel
    @State private var storeText = ""
    @State private var problem: String?
    @State private var isInstalling = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField(L10n.string("extensions.storeField"), text: $storeText)
                    .onSubmit(installFromStore)
                Button(L10n.string("extensions.storeInstall"), action: installFromStore)
                    .disabled(ChromeWebStore.extensionID(from: storeText) == nil || isInstalling)
            }
            HStack {
                Button(L10n.string("extensions.loadUnpacked")) { choose(folders: true) }
                Button(L10n.string("extensions.installFile")) { choose(folders: false) }
                if isInstalling { ProgressView().controlSize(.small) }
            }
            Toggle(L10n.string("extensions.checkUpdates"), isOn: $model.checksForUpdates)
            if let problem {
                Text(problem).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if model.entries.isEmpty {
                Text(L10n.string("extensions.empty"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(model.entries) { row($0) }
            }
        }
    }

    private func row(_ entry: ExtensionEntry) -> some View {
        HStack {
            if let icon = entry.icon { Image(nsImage: icon).resizable().frame(width: 24, height: 24) }
            VStack(alignment: .leading) {
                Text(entry.name).lineLimit(1)
                Text(entry.version).font(.caption).foregroundStyle(.secondary)
                ForEach(entry.problems, id: \.self) {
                    Text($0).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            Toggle(L10n.string("extensions.showInToolbar"), isOn: Binding {
                entry.isPinned
            } set: {
                model.commands?.setPinned(entry.id, $0)
            })
            Toggle(L10n.string("extensions.enabled"), isOn: Binding {
                entry.isEnabled
            } set: {
                model.commands?.setEnabled(entry.id, $0)
            })
            .labelsHidden()
            Button(L10n.string("history.delete")) {
                let title = String(format: L10n.string("extensions.removeConfirm"), entry.name)
                guard Prompts.confirmDelete(title, detail: L10n.string("extensions.removeDetail")) else { return }
                Task { await model.commands?.remove(entry.id) }
            }
        }
    }

    private func choose(folders: Bool) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = folders
        panel.canChooseFiles = !folders
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run { try await model.commands?.install(from: url) }
    }

    private func installFromStore() {
        guard let id = ChromeWebStore.extensionID(from: storeText) else { return }
        run {
            try await model.commands?.installFromStore(id: id)
            storeText = ""
        }
    }

    private func run(_ work: @escaping () async throws -> Void) {
        problem = nil
        isInstalling = true
        Task {
            do {
                try await work()
            } catch {
                // Declining the permissions is a choice, not a failure.
                if error as? ExtensionInstallError != .declined { problem = L10n.string("extensions.installFailed") }
            }
            isInstalling = false
        }
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
