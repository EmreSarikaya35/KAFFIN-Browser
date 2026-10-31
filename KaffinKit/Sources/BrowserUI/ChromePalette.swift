import AppKit
import SwiftUI

/// Chrome's neutral light and dark surfaces: the strip recedes, the active tab and toolbar share one color.
enum ChromePalette {
    static let strip = adaptive(light: 0xDEE1E6, dark: 0x202124)
    static let toolbar = adaptive(light: 0xFFFFFF, dark: 0x35363A)
    static let field = adaptive(light: 0xF1F3F4, dark: 0x202124)

    private static func adaptive(light: Int, dark: Int) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return color(isDark ? dark : light)
        })
    }

    private static func color(_ hex: Int) -> NSColor {
        NSColor(
            srgbRed: CGFloat(hex >> 16 & 0xFF) / 255,
            green: CGFloat(hex >> 8 & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}
