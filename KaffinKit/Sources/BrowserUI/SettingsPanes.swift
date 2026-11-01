import AppKit
import BrowserCore
import SwiftUI

struct GeneralSettingsView: View {
    @Bindable private var settings = BrowserPreferences.shared
    let onSetDefault: () -> Void

    var body: some View {
        Form {
            Section(L10n.string("settings.onStartup")) {
                Picker(L10n.string("settings.onStartup"), selection: $settings.startup) {
                    ForEach(StartupBehavior.allCases, id: \.self) { Text(L10n.string("startup.\($0.rawValue)")).tag($0) }
                }
                .labelsHidden()
                .pickerStyle(.radioGroup)
                if settings.startup == .pages {
                    TextField(L10n.string("startup.pagesField"), text: $settings.startupPages, axis: .vertical)
                        .lineLimit(2...6)
                }
            }
            Section(L10n.string("settings.defaultBrowser")) {
                Button(L10n.string("menu.setDefault"), action: onSetDefault)
            }
            Section(L10n.string("settings.system")) {
                Toggle(L10n.string("settings.warnQuit"), isOn: $settings.warnsBeforeQuitting)
            }
        }
    }
}

struct AppearanceSettingsView: View {
    @Bindable private var settings = BrowserPreferences.shared
    let accent: AccentSettings
    @Bindable var bookmarks: BookmarksModel

    private static let zoomLevels = [0.75, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2]
    private static let fontSizes = [0, 9, 10, 12, 14, 16, 18, 24]

    var body: some View {
        Form {
            Section(L10n.string("settings.theme")) {
                Picker(L10n.string("settings.themeMode"), selection: $settings.theme) {
                    ForEach(AppTheme.allCases, id: \.self) { Text(L10n.string("appearance.\($0.rawValue)")).tag($0) }
                }
                HStack {
                    ColorPicker(L10n.string("settings.accent"), selection: accentColor, supportsOpacity: false)
                    if accent.color != nil {
                        Button(L10n.string("settings.accentReset")) { accent.color = nil }
                    }
                }
            }
            Section(L10n.string("settings.toolbar")) {
                Toggle(L10n.string("settings.homeButton"), isOn: $settings.showsHomeButton)
                if settings.showsHomeButton {
                    TextField(L10n.string("settings.homePage"), text: $settings.homePage, prompt: Text(L10n.string("settings.homePageHint")))
                }
                Toggle(L10n.string("settings.bookmarksBar"), isOn: $bookmarks.isBarVisible)
            }
            Section(L10n.string("settings.pages")) {
                Picker(L10n.string("settings.pageZoom"), selection: $settings.pageZoom) {
                    ForEach(Self.zoomLevels, id: \.self) { Text($0.formatted(.percent)).tag($0) }
                }
                Picker(L10n.string("settings.minimumFont"), selection: $settings.minimumFontSize) {
                    ForEach(Self.fontSizes, id: \.self) { size in
                        Text(size == 0 ? L10n.string("settings.noMinimum") : "\(size)").tag(size)
                    }
                }
            }
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
}

struct SearchSettingsView: View {
    @Bindable private var settings = BrowserPreferences.shared
    let search: SearchSettings
    @State private var template = ""
    @State private var isTemplateInvalid = false

    var body: some View {
        Form {
            Section {
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
                Toggle(L10n.string("settings.suggestions"), isOn: $settings.showsSuggestions)
            }
        }
        .onAppear {
            if search.engine.name == SearchSettings.customName { template = search.engine.queryTemplate }
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

struct PasswordsPaneView: View {
    @Bindable private var settings = BrowserPreferences.shared
    let model: PasswordsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(L10n.string("settings.offerSave"), isOn: $settings.offersToSavePasswords)
            Toggle(L10n.string("settings.offerFill"), isOn: $settings.offersToFillPasswords)
            Divider()
            PasswordsSettingsView(model: model)
        }
        .padding(.horizontal, 20)
    }
}

struct PrivacySettingsView: View {
    @Bindable private var settings = BrowserPreferences.shared
    let onClearData: (ClearDataRequest) async -> Void

    @State private var clearsHistory = true
    @State private var clearsSiteData = true
    @State private var clearsCache = true
    @State private var range = ClearDataRange.day
    @State private var isClearing = false
    @State private var didClear = false

    var body: some View {
        Form {
            Section(L10n.string("privacy.clearTitle")) {
                Picker(L10n.string("privacy.range"), selection: $range) {
                    ForEach(ClearDataRange.allCases, id: \.self) { Text(L10n.string("privacy.range.\($0.rawValue)")).tag($0) }
                }
                Toggle(L10n.string("privacy.clearHistory"), isOn: $clearsHistory)
                Toggle(L10n.string("privacy.clearSiteData"), isOn: $clearsSiteData)
                Toggle(L10n.string("privacy.clearCache"), isOn: $clearsCache)
                HStack {
                    Button(L10n.string("privacy.clearAction"), action: clear)
                        .disabled(isClearing || !(clearsHistory || clearsSiteData || clearsCache))
                    if isClearing { ProgressView().controlSize(.small) }
                    if didClear { Text(L10n.string("privacy.cleared")).foregroundStyle(.secondary) }
                }
            }
            Section(L10n.string("privacy.security")) {
                Toggle(L10n.string("privacy.fraud"), isOn: $settings.warnsAboutFraud)
                Toggle(L10n.string("privacy.https"), isOn: $settings.alwaysUsesHTTPS)
                Toggle(L10n.string("privacy.lockdown"), isOn: $settings.usesLockdownMode)
                Text(L10n.string("privacy.lockdownDetail")).font(.caption).foregroundStyle(.secondary)
            }
            Section(L10n.string("privacy.content")) {
                Toggle(L10n.string("privacy.javascript"), isOn: $settings.allowsJavaScript)
                Toggle(L10n.string("privacy.popups"), isOn: $settings.allowsPopups)
                Text(L10n.string("privacy.cookiesNote")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func clear() {
        guard Prompts.confirm(L10n.string("privacy.clearConfirm"), detail: L10n.string("privacy.clearDetail"), action: L10n.string("privacy.clearAction")) else { return }
        isClearing = true
        didClear = false
        Task {
            await onClearData(ClearDataRequest(history: clearsHistory, siteData: clearsSiteData, cache: clearsCache, since: range.startDate()))
            isClearing = false
            didClear = true
        }
    }
}

struct DownloadsSettingsView: View {
    @Bindable private var settings = BrowserPreferences.shared
    @State private var problem = false

    private var folderName: String {
        settings.downloadFolder?.path(percentEncoded: false) ?? L10n.string("settings.downloadsDefault")
    }

    var body: some View {
        Form {
            Section {
                LabeledContent(L10n.string("settings.downloadLocation")) {
                    Text(folderName).lineLimit(1).truncationMode(.middle)
                }
                HStack {
                    Button(L10n.string("settings.downloadChange"), action: chooseFolder)
                    if settings.downloadFolderBookmark != nil {
                        Button(L10n.string("settings.accentReset")) { try? settings.setDownloadFolder(nil) }
                    }
                }
                if problem { Text(L10n.string("settings.downloadFailed")).foregroundStyle(.secondary) }
                Toggle(L10n.string("settings.askWhereToSave"), isOn: $settings.asksWhereToSave)
                Toggle(L10n.string("settings.showDownloads"), isOn: $settings.showsDownloadsWhenStarted)
            }
        }
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try settings.setDownloadFolder(url)
            problem = false
        } catch {
            problem = true
        }
    }
}

struct AccessibilitySettingsView: View {
    @Bindable private var settings = BrowserPreferences.shared

    var body: some View {
        Form {
            Section {
                Toggle(L10n.string("settings.tabLinks"), isOn: $settings.tabHighlightsLinks)
                Text(L10n.string("settings.accessibilityNote")).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct ResetSettingsView: View {
    @State private var didReset = false

    var body: some View {
        Form {
            Section {
                Text(L10n.string("settings.resetDetail")).foregroundStyle(.secondary)
                HStack {
                    Button(L10n.string("settings.resetAction")) {
                        if Prompts.confirm(L10n.string("settings.resetConfirm"), detail: L10n.string("settings.resetDetail"), action: L10n.string("settings.resetAction")) {
                            BrowserPreferences.shared.reset()
                            didReset = true
                        }
                    }
                    if didReset { Text(L10n.string("settings.resetDone")).foregroundStyle(.secondary) }
                }
            }
        }
    }
}

struct AboutSettingsView: View {
    private static let repository = "https://github.com/EmreSarikaya35/KAFFIN-Browser"
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
    }

    var body: some View {
        Form {
            Section {
                LabeledContent(L10n.string("settings.version"), value: version).textSelection(.enabled)
                LabeledContent(L10n.string("settings.license"), value: "MIT")
                if let source = URL(string: Self.repository), let releases = URL(string: "\(Self.repository)/releases") {
                    Link(L10n.string("settings.sourceCode"), destination: source)
                    Link(L10n.string("settings.checkUpdates"), destination: releases)
                }
            }
        }
    }
}
