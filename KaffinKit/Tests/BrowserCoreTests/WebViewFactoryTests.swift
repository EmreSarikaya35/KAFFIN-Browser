import BrowserCore
import Foundation
import Testing
import WebKit

@MainActor
struct WebViewFactoryTests {
    @Test func privateSessionsNeverPersistWebsiteData() {
        #expect(!WebViewFactory.privateSession().makeConfiguration().websiteDataStore.isPersistent)
    }

    @Test func profilesPersistWebsiteData() {
        #expect(WebViewFactory(profileID: UUID()).makeConfiguration().websiteDataStore.isPersistent)
    }

    @Test func eachPrivateSessionIsIsolated() {
        let first = WebViewFactory.privateSession().makeConfiguration().websiteDataStore
        let second = WebViewFactory.privateSession().makeConfiguration().websiteDataStore
        #expect(first !== second)
    }
}
