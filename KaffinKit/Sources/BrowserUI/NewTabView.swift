import AppKit
import BrowserCore
import SwiftUI

/// Native, so a new tab costs no web process and runs no script.
public struct NewTabView: View {
    let onSubmit: (String) -> Void
    @State private var text = ""

    public init(onSubmit: @escaping (String) -> Void) {
        self.onSubmit = onSubmit
    }

    public var body: some View {
        VStack(spacing: 28) {
            Text(verbatim: "KAFFIN")
                .font(.system(size: 44, weight: .semibold))
            TextField(L10n.string("address.placeholder"), text: $text)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .padding(.horizontal, 18)
                .frame(height: 44)
                .background(ChromePalette.field, in: Capsule())
                .frame(maxWidth: 560)
                .onSubmit {
                    onSubmit(text)
                    text = ""
                }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ChromePalette.toolbar)
    }
}
