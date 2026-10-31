import CoreGraphics

/// Geometry of a live tab drag. Translation is measured from where the drag started.
/// The range is the tab's group, because pinned and normal tabs never mix.
public enum TabDragLayout {
    public static func targetIndex(start: Int, range: ClosedRange<Int>, translation: CGFloat, tabWidth: CGFloat) -> Int {
        guard tabWidth > 0 else { return start }
        let slots = Int((translation / tabWidth).rounded())
        return min(range.upperBound, max(range.lowerBound, start + slots))
    }

    /// Offset from the tab's current slot that keeps it under the pointer, limited to its group.
    public static func offset(
        start: Int,
        current: Int,
        range: ClosedRange<Int>,
        translation: CGFloat,
        tabWidth: CGFloat
    ) -> CGFloat {
        let offset = translation - CGFloat(current - start) * tabWidth
        let lowest = -CGFloat(current - range.lowerBound) * tabWidth
        return min(CGFloat(range.upperBound - current) * tabWidth, max(lowest, offset))
    }
}
