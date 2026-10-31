import BrowserCore
import Foundation
import Testing
@testable import Tabs

@MainActor
struct TabManagerTests {
    private func makeManager() -> TabManager {
        TabManager(factory: WebViewFactory(profileID: UUID()))
    }

    @Test func newTabOpensNextToSelectedTabAndActivates() {
        let manager = makeManager()
        let first = manager.newTab()
        let third = manager.newTab()
        manager.select(first.id)
        let second = manager.newTab()

        #expect(manager.tabs.map(\.id) == [first.id, second.id, third.id])
        #expect(manager.selectedTabID == second.id)
        #expect(second.state == .active)
        #expect(first.state == .background)
    }

    @Test func closingSelectedTabSelectsItsNeighbor() {
        let manager = makeManager()
        let first = manager.newTab()
        let second = manager.newTab()
        let third = manager.newTab()
        manager.select(second.id)

        manager.close(second.id)
        #expect(manager.selectedTabID == third.id)

        manager.close(third.id)
        #expect(manager.selectedTabID == first.id)
        #expect(first.state == .active)
    }

    @Test func closingBackgroundTabKeepsSelection() {
        let manager = makeManager()
        let first = manager.newTab()
        let second = manager.newTab()

        manager.close(first.id)
        #expect(manager.selectedTabID == second.id)
    }

    @Test func closingLastTabNotifiesWindow() {
        let manager = makeManager()
        var closed = false
        manager.onLastTabClosed = { closed = true }

        manager.close(manager.newTab().id)
        #expect(closed)
        #expect(manager.selectedTab == nil)
    }

    @Test func adjacentSelectionWraps() {
        let manager = makeManager()
        let first = manager.newTab()
        let second = manager.newTab()

        manager.selectAdjacentTab(offset: 1)
        #expect(manager.selectedTabID == first.id)
        manager.selectAdjacentTab(offset: -1)
        #expect(manager.selectedTabID == second.id)
    }

    @Test func crashedBackgroundTabFailsAndRecoversOnSelection() {
        let manager = makeManager()
        let background = manager.newTab(select: false)
        let selected = manager.newTab()

        manager.handleContentProcessTermination(of: background)
        #expect(background.state == .failed)

        manager.select(background.id)
        #expect(background.state == .restoring)
        #expect(selected.state == .background)

        manager.handleLoadFinished(of: background)
        #expect(background.state == .active)
    }
}
