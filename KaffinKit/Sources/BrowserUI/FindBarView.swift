import BrowserCore
import SwiftUI

public struct FindBarView: View {
    let focusRequest: Int
    let onSearch: (String, Bool) async -> Bool
    let onClose: () -> Void

    @State private var text = ""
    @State private var hasMatch = true
    @FocusState private var isFocused: Bool

    public init(
        focusRequest: Int,
        onSearch: @escaping (String, Bool) async -> Bool,
        onClose: @escaping () -> Void
    ) {
        self.focusRequest = focusRequest
        self.onSearch = onSearch
        self.onClose = onClose
    }

    public var body: some View {
        HStack(spacing: 8) {
            TextField(L10n.string("find.placeholder"), text: $text)
                .textFieldStyle(.plain)
                .frame(width: 180)
                .focused($isFocused)
                .onSubmit { search(backwards: false) }
                .onChange(of: text) { search(backwards: false) }
                .onExitCommand(perform: onClose)
            if !hasMatch {
                Text(L10n.string("find.notFound")).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            button("chevron.up", "find.previous") { search(backwards: true) }
            button("chevron.down", "find.next") { search(backwards: false) }
            button("xmark", "find.done", action: onClose)
        }
        .padding(.horizontal, 12)
        .frame(height: 38)
        .background(ChromePalette.toolbar, in: RoundedRectangle(cornerRadius: 8))
        .shadow(radius: 3, y: 1)
        .padding(4)
        .task(id: focusRequest) { isFocused = true }
    }

    private func button(_ symbol: String, _ key: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol).frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(L10n.string(key))
    }

    private func search(backwards: Bool) {
        let query = text
        Task {
            let found = await onSearch(query, backwards)
            if query == text { hasMatch = found }
        }
    }
}
