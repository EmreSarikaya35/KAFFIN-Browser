import AppKit
import BrowserCore
import SwiftUI
import UniformTypeIdentifiers

struct ImportSettingsView: View {
    let model: BrowserImportModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(L10n.string("import.detail")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if model.browsers.isEmpty {
                Text(L10n.string("import.none")).foregroundStyle(.secondary)
            }
            ForEach(model.browsers) { browser in
                HStack {
                    Text(browser.name)
                    Spacer()
                    Button(L10n.string("import.action")) { Task { await model.start(browser) } }
                        .disabled(model.isImporting)
                }
            }
            Divider()
            Text(L10n.string("import.fileDetail")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button(L10n.string("import.passwordsCSV")) { chooseFile(.commaSeparatedText) }
                Button(L10n.string("import.bookmarksHTML")) { chooseFile(.html) }
                Button(L10n.string("import.safariZIP")) { chooseFile(.zip) }
            }
            .disabled(model.isImporting)
            if model.isImporting {
                ProgressView().controlSize(.small)
            }
            if model.needsDiskAccess {
                Text(L10n.string("import.diskAccess")).fixedSize(horizontal: false, vertical: true)
                Button(L10n.string("import.openDiskAccess")) {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
                        NSWorkspace.shared.open(url)
                    }
                }
            }
            if model.didFail {
                Text(L10n.string("import.failed")).foregroundStyle(.secondary)
            }
            if let summary = model.summary {
                Text(String(format: L10n.string("import.done"), summary.bookmarks, summary.history, summary.passwords))
                if summary.couldNotReadPasswords {
                    Text(L10n.string("import.passwordsFailed")).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 20)
        .frame(maxHeight: .infinity, alignment: .top)
        .task { model.reload() }
    }

    private func chooseFile(_ type: UTType) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [type]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.start(file: url) }
    }
}
