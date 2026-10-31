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

    @Test func movesTabLeftAndRight() {
        let manager = makeManager()
        let first = manager.newTab()
        let second = manager.newTab()
        let third = manager.newTab()

        manager.move(first.id, to: 2)
        #expect(manager.tabs.map(\.id) == [second.id, third.id, first.id])
        manager.move(first.id, to: 0)
        #expect(manager.tabs.map(\.id) == [first.id, second.id, third.id])
        #expect(manager.selectedTabID == third.id)
    }

    @Test func moveIgnoresUnknownTabAndClampsIndex() {
        let manager = makeManager()
        let first = manager.newTab()
        let second = manager.newTab()

        manager.move(UUID(), to: 0)
        #expect(manager.tabs.map(\.id) == [first.id, second.id])
        manager.move(first.id, to: 99)
        #expect(manager.tabs.map(\.id) == [second.id, first.id])
    }

    @Test func closeOthersKeepsOnlyGivenTab() {
        let manager = makeManager()
        _ = manager.newTab()
        let kept = manager.newTab()
        _ = manager.newTab()

        manager.closeOthers(than: kept.id)
        #expect(manager.tabs.map(\.id) == [kept.id])
        #expect(manager.selectedTabID == kept.id)
    }

    @Test func reopensMostRecentlyClosedTabWithAddress() async throws {
        let manager = makeManager()
        _ = manager.newTab()
        let closed = manager.newTab(url: URL(string: "about:blank#closed"))
        try await waitForURL(of: closed)

        manager.close(closed.id)
        let reopened = try #require(manager.reopenClosedTab())
        try await waitForURL(of: reopened)
        #expect(reopened.url?.absoluteString == "about:blank#closed")
        #expect(manager.selectedTabID == reopened.id)
        #expect(manager.tabs.count == 2)
        #expect(manager.reopenClosedTab() == nil)
    }

    @Test func blankTabIsNotRemembered() {
        let manager = makeManager()
        _ = manager.newTab()
        manager.close(manager.newTab().id)
        #expect(manager.reopenClosedTab() == nil)
    }

    private func waitForURL(of tab: Tab) async throws {
        for _ in 0..<100 where tab.url == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(tab.url != nil)
    }
}
