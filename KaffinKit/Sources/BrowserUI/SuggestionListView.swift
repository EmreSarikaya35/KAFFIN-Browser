import BrowserCore
import SwiftUI

public struct SuggestionListView: View {
    let model: SuggestionsModel
    let onPick: (Suggestion) -> Void

    public init(model: SuggestionsModel, onPick: @escaping (Suggestion) -> Void) {
        self.model = model
        self.onPick = onPick
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(model.items) { item in
                Button {
                    onPick(item)
                } label: {
                    row(item)
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(model.isHighlighted(item) ? .isSelected : [])
            }
        }
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ChromePalette.toolbar, in: RoundedRectangle(cornerRadius: 10))
        .shadow(radius: 5, y: 2)
        .padding(.horizontal, 6)
        .padding(.bottom, 8)
        // Focus stays in the address field, so VoiceOver would not notice the arrow keys.
        .onChange(of: model.selected) { _, item in
            if let item { AccessibilityNotification.Announcement(item.title).post() }
        }
    }

    private func row(_ item: Suggestion) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol(for: item.kind))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: 16)
                .accessibilityHidden(true)
            Text(item.title).lineLimit(1)
            if !item.detail.isEmpty {
                Text(item.detail).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 13))
        .padding(.horizontal, 14)
        .frame(height: 30)
        .contentShape(Rectangle())
        .background(model.isHighlighted(item) ? ChromePalette.field : .clear)
    }

    private func symbol(for kind: Suggestion.Kind) -> String {
        switch kind {
        case .search: "magnifyingglass"
        case .site, .address: "globe"
        case .bookmark: "star"
        case .history: "clock"
        }
    }
}
