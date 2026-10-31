import Testing
import Tabs

struct TabLifecycleStateTests {
    @Test func followsPlannedSleepAndRestoreCycle() {
        #expect(TabLifecycleState.active.canTransition(to: .background))
        #expect(TabLifecycleState.background.canTransition(to: .sleeping))
        #expect(TabLifecycleState.sleeping.canTransition(to: .restoring))
        #expect(TabLifecycleState.restoring.canTransition(to: .active))
    }

    @Test func activeTabCannotSleep() {
        #expect(!TabLifecycleState.active.canTransition(to: .sleeping))
    }

    @Test func sleepingTabMustRestoreBeforeActivating() {
        #expect(!TabLifecycleState.sleeping.canTransition(to: .active))
    }

    @Test func failedTabRecoversThroughRestoring() {
        #expect(TabLifecycleState.failed.canTransition(to: .restoring))
        #expect(!TabLifecycleState.failed.canTransition(to: .active))
    }
}
