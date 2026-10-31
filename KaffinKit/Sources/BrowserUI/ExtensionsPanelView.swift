import AppKit
import BrowserCore
import SwiftUI

/// Everything about extensions in one toolbar popover, so managing them never leaves the page.
public struct ExtensionsPanelView: View {
    @Bindable var model: ExtensionsModel
    let onDismiss: () -> Void
    @State private var storeText = ""
    @State private var problem: String?
    @State private var isInstalling = false

    public init(model: ExtensionsModel, onDismiss: @escaping () -> Void) {
        self.model = model
        self.onDismiss = onDismiss
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(L10n.string("extensions.title")).font(.headline)
            if model.entries.isEmpty {
                Text(L10n.string("extensions.empty")).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(model.entries) { row($0) }
                    }
                }
                .frame(maxHeight: 260)
                .fixedSize(horizontal: false, vertical: true)
            }
            Divider()
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
        }
        .padding(14)
        .frame(width: 400)
    }

    private func row(_ entry: ExtensionEntry) -> some View {
        HStack(spacing: 8) {
            Button {
                onDismiss()
                model.commands?.performAction(entry.id)
            } label: {
                HStack(spacing: 8) {
                    if let icon = entry.icon {
                        Image(nsImage: icon).resizable().frame(width: 20, height: 20)
                    } else {
                        Image(systemName: "puzzlepiece.extension").frame(width: 20, height: 20)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(entry.name).lineLimit(1)
                        Text(entry.version).font(.caption).foregroundStyle(.secondary)
                        ForEach(entry.problems, id: \.self) {
                            Text($0).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                        }
                    }
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(!entry.isEnabled)
            Button {
                model.commands?.setPinned(entry.id, !entry.isPinned)
            } label: {
                Image(systemName: entry.isPinned ? "pin.fill" : "pin")
            }
            .buttonStyle(.borderless)
            .help(L10n.string("extensions.showInToolbar"))
            .accessibilityLabel(L10n.string("extensions.showInToolbar"))
            .accessibilityAddTraits(entry.isPinned ? .isSelected : [])
            Toggle(L10n.string("extensions.enabled"), isOn: Binding {
                entry.isEnabled
            } set: {
                model.commands?.setEnabled(entry.id, $0)
            })
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.mini)
            Button {
                let title = String(format: L10n.string("extensions.removeConfirm"), entry.name)
                guard Prompts.confirmDelete(title, detail: L10n.string("extensions.removeDetail")) else { return }
                Task { await model.commands?.remove(entry.id) }
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .help(L10n.string("history.delete"))
            .accessibilityLabel(L10n.string("history.delete"))
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
