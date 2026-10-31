import CoreGraphics

/// Geometry of a live tab drag. Translation is measured from where the drag started.
public enum TabDragLayout {
    public static func targetIndex(start: Int, count: Int, translation: CGFloat, tabWidth: CGFloat) -> Int {
        guard tabWidth > 0 else { return start }
        let slots = Int((translation / tabWidth).rounded())
        return min(count - 1, max(0, start + slots))
    }

    /// Offset from the tab's current slot that keeps it under the pointer, limited to the strip.
    public static func offset(start: Int, current: Int, count: Int, translation: CGFloat, tabWidth: CGFloat) -> CGFloat {
        let offset = translation - CGFloat(current - start) * tabWidth
        return min(CGFloat(count - 1 - current) * tabWidth, max(-CGFloat(current) * tabWidth, offset))
    }
}
