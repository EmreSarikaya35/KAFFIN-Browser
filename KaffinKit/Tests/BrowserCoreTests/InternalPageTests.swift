import BrowserCore
import Foundation
import Testing

struct InternalPageTests {
    @Test(arguments: InternalPage.allCases) func pageRoundTripsThroughItsURL(page: InternalPage) {
        #expect(InternalPage(url: page.url) == page)
    }

    @Test(arguments: ["kaffin://unknown", "kaffin://", "https://settings", "about:blank"])
    func otherURLsAreNotInternalPages(text: String) throws {
        #expect(InternalPage(url: try #require(URL(string: text))) == nil)
    }

    @Test func addressBarOpensInternalPages() {
        #expect(AddressResolver.resolve("kaffin://settings") == InternalPage.settings.url)
    }

    @Test func websitesCannotNavigateToInternalPages() {
        #expect(LinkPolicy.decision(scheme: InternalPage.scheme, isMainFrame: true, isLinkClick: true) == .block)
    }
}
