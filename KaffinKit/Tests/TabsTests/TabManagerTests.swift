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

    @Test func restoresTabsLazilyWithSavedSelection() {
        let manager = makeManager()
        let first = URL(string: "https://example.com/one")!
        let second = URL(string: "https://example.com/two")!

        manager.restore(SessionWindow(tabs: [
            SessionTab(url: first, title: "One", isSelected: false, interactionState: nil),
            SessionTab(url: second, title: "Two", isSelected: true, interactionState: nil),
        ]))

        #expect(manager.tabs.map(\.url) == [first, second])
        #expect(manager.tabs.map(\.title) == ["One", "Two"])
        #expect(manager.selectedTab?.url == second)
        // Only the selected tab may start loading; background tabs wait for selection.
        #expect(manager.tabs[0].isAwaitingLoad)
        #expect(!manager.tabs[1].isAwaitingLoad)
    }

    @Test func selectingRestoredTabStartsItsLoad() {
        let manager = makeManager()
        manager.restore(SessionWindow(tabs: [
            SessionTab(url: URL(string: "about:blank#one")!, title: nil, isSelected: false, interactionState: nil),
            SessionTab(url: URL(string: "about:blank#two")!, title: nil, isSelected: true, interactionState: nil),
        ]))

        manager.select(manager.tabs[0].id)
        #expect(!manager.tabs[0].isAwaitingLoad)
    }

    @Test func snapshotKeepsOrderSelectionAndUnloadedTabs() {
        let manager = makeManager()
        let session = SessionWindow(tabs: [
            SessionTab(url: URL(string: "about:blank#one")!, title: "One", isSelected: false, interactionState: Data([7])),
            SessionTab(url: URL(string: "about:blank#two")!, title: "Two", isSelected: true, interactionState: nil),
        ])
        manager.restore(session)

        let snapshot = manager.snapshot()
        #expect(snapshot.tabs.map(\.url) == session.tabs.map(\.url))
        #expect(snapshot.tabs.map(\.isSelected) == [false, true])
        #expect(snapshot.tabs[0].interactionState == Data([7]))
    }

    @Test func snapshotLeavesOutBlankTabs() {
        let manager = makeManager()
        manager.newTab()
        #expect(manager.snapshot().tabs.isEmpty)
    }

    @Test func changesNotifySessionSaver() {
        let manager = makeManager()
        var changes = 0
        manager.onChange = { changes += 1 }

        let first = manager.newTab()
        let second = manager.newTab()
        manager.select(first.id)
        manager.move(first.id, to: 1)
        manager.close(second.id)
        #expect(changes >= 5)
    }

    @Test func loadedTabSnapshotCarriesWebKitState() async throws {
        let manager = makeManager()
        let tab = manager.newTab(url: URL(string: "about:blank#state"))
        try await waitForURL(of: tab)
        for _ in 0..<100 where tab.isLoading {
            try await Task.sleep(for: .milliseconds(20))
        }

        #expect(manager.snapshot().tabs.first?.interactionState != nil)
    }

    private func waitForURL(of tab: Tab) async throws {
        for _ in 0..<100 where tab.url == nil {
            try await Task.sleep(for: .milliseconds(20))
        }
        try #require(tab.url != nil)
    }
}