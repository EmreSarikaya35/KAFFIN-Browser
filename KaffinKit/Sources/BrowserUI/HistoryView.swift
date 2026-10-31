import BrowserCore
import SwiftUI

public struct HistoryView: View {
    @Bindable var model: HistoryModel
    let onOpen: (URL) -> Void
    @State private var isConfirmingClear = false

    public init(model: HistoryModel, onOpen: @escaping (URL) -> Void) {
        self.model = model
        self.onOpen = onOpen
    }

    private var days: [(day: Date, entries: [HistoryEntry])] {
        Dictionary(grouping: model.entries) { Calendar.current.startOfDay(for: $0.lastVisit) }
            .sorted { $0.key > $1.key }
            .map { ($0.key, $0.value) }
    }

    public var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 12) {
                TextField(L10n.string("history.search"), text: $model.query)
                    .textFieldStyle(.roundedBorder)
                Button(L10n.string("history.clear")) { isConfirmingClear = true }
                    .disabled(model.entries.isEmpty)
            }
            .padding(12)
            Divider()
            if model.entries.isEmpty {
                Text(L10n.string(model.query.isEmpty ? "history.empty" : "history.noResults"))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                list
            }
        }
        .frame(minWidth: 480, minHeight: 360)
        .confirmationDialog(L10n.string("history.clearConfirm"), isPresented: $isConfirmingClear) {
            Button(L10n.string("history.clear"), role: .destructive) {
                Task { await model.clear() }
            }
            Button(L10n.string("history.cancel"), role: .cancel) {}
        } message: {
            Text(L10n.string("history.clearDetail"))
        }
    }

    private var list: some View {
        List {
            ForEach(days, id: \.day) { day in
                Section(day.day.formatted(date: .complete, time: .omitted)) {
                    ForEach(day.entries) { entry in
                        Button {
                            onOpen(entry.url)
                        } label: {
                            HStack {
                                Text(entry.lastVisit.formatted(date: .omitted, time: .shortened))
                                    .foregroundStyle(.secondary)
                                Text(entry.title ?? entry.url.absoluteString).lineLimit(1)
                                Text(entry.url.host() ?? "").foregroundStyle(.secondary).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .contextMenu {
                            Button(L10n.string("history.delete")) {
                                Task { await model.delete(entry) }
                            }
                        }
                    }
                }
            }
        }
    }
}
