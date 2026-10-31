import BrowserCore
import Foundation
import Testing
import WebKit

@MainActor
struct ProfileListTests {
    private func makeDefaults() -> UserDefaults {
        UserDefaults(suiteName: "kaffin-test-\(UUID())")!
    }

    @Test func startsWithDefaultProfile() {
        let list = ProfileList(defaults: makeDefaults())
        #expect(list.profiles.map(\.id) == [WebViewFactory.defaultProfileID])
    }

    @Test func addedProfileSurvivesRestart() throws {
        let defaults = makeDefaults()
        let added = try #require(ProfileList(defaults: defaults).add(name: "  İş  "))

        #expect(added.name == "İş")
        #expect(ProfileList(defaults: defaults).profiles.map(\.id) == [WebViewFactory.defaultProfileID, added.id])
    }

    @Test func blankNameIsRefused() {
        let list = ProfileList(defaults: makeDefaults())
        #expect(list.add(name: "   ") == nil)
        #expect(list.profiles.count == 1)
    }

    @Test func renamePersistsAndRefusesBlank() throws {
        let defaults = makeDefaults()
        let list = ProfileList(defaults: defaults)
        let added = try #require(list.add(name: "Old"))

        list.rename(added.id, to: "New")
        list.rename(added.id, to: "  ")
        #expect(ProfileList(defaults: defaults).profiles.last?.name == "New")
    }

    @Test func removePersists() throws {
        let defaults = makeDefaults()
        let list = ProfileList(defaults: defaults)
        let added = try #require(list.add(name: "Gone"))

        #expect(list.remove(added.id))
        #expect(ProfileList(defaults: defaults).profiles.count == 1)
    }

    @Test func defaultProfileCannotBeRemoved() {
        let list = ProfileList(defaults: makeDefaults())
        #expect(!list.remove(WebViewFactory.defaultProfileID))
        #expect(list.profiles.count == 1)
    }

    @Test func damagedStorageStillGivesDefaultProfile() {
        let defaults = makeDefaults()
        defaults.set(Data("not json".utf8), forKey: "profiles")
        #expect(ProfileList(defaults: defaults).profiles.map(\.id) == [WebViewFactory.defaultProfileID])
    }
}

@MainActor
struct ProfileIsolationTests {
    private func cookie(_ name: String) -> HTTPCookie {
        HTTPCookie(properties: [.domain: "example.com", .path: "/", .name: name, .value: "1"])!
    }

    @Test func cookiesStayInsideTheirProfile() async {
        let first = WebViewFactory(profileID: UUID()).makeConfiguration().websiteDataStore
        let second = WebViewFactory(profileID: UUID()).makeConfiguration().websiteDataStore

        await first.httpCookieStore.setCookie(cookie("secret"))

        #expect(await first.httpCookieStore.allCookies().map(\.name) == ["secret"])
        #expect(await second.httpCookieStore.allCookies().isEmpty)
    }

    @Test func removingProfileDataDeletesItsStore() async throws {
        let id = UUID()
        do {
            let store = WebViewFactory(profileID: id).makeConfiguration().websiteDataStore
            await store.httpCookieStore.setCookie(cookie("gone"))
        }
        #expect(await WKWebsiteDataStore.allDataStoreIdentifiers.contains(id))

        try await WebViewFactory.removeProfileData(id)
        #expect(await !WKWebsiteDataStore.allDataStoreIdentifiers.contains(id))
    }
}
