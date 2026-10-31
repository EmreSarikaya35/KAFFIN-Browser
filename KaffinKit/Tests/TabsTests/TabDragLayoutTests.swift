import Tabs
import Testing

struct TabDragLayoutTests {
    @Test(arguments: [
        (0.0, 1), (40.0, 1), (60.0, 2), (150.0, 3), (-60.0, 0), (900.0, 3), (-900.0, 0),
    ])
    func targetSlotFollowsPointer(translation: Double, expected: Int) {
        #expect(TabDragLayout.targetIndex(start: 1, count: 4, translation: translation, tabWidth: 100) == expected)
    }

    @Test func staysPutWithoutWidth() {
        #expect(TabDragLayout.targetIndex(start: 2, count: 4, translation: 50, tabWidth: 0) == 2)
    }

    @Test func draggedTabStaysUnderPointerAfterSwap() {
        #expect(TabDragLayout.offset(start: 0, current: 1, count: 3, translation: 130, tabWidth: 100) == 30)
    }

    @Test func draggedTabCannotLeaveStrip() {
        #expect(TabDragLayout.offset(start: 2, current: 2, count: 3, translation: 500, tabWidth: 100) == 0)
        #expect(TabDragLayout.offset(start: 0, current: 0, count: 3, translation: -500, tabWidth: 100) == 0)
    }
}
