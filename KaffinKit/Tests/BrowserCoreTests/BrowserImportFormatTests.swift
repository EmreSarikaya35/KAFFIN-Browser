import BrowserCore
import Foundation
import Testing

struct BrowserImportFormatTests {
    @Test func chromiumDatesStartIn1601() {
        #expect(BrowserImportFormat.chromiumDate(11_644_473_600_000_000) == Date(timeIntervalSince1970: 0))
    }

    @Test func chromiumBookmarksKeepTheBarAndOtherRoots() {
        let json = #"""
        {"roots":{
          "bookmark_bar":{"name":"Bookmarks bar","type":"folder","children":[
            {"type":"url","name":"Site","url":"https://site.example/"},
            {"type":"url","name":"Script","url":"javascript:alert(1)"},
            {"type":"folder","name":"Work","children":[{"type":"url","name":"Doc","url":"https://doc.example/"}]}
          ]},
          "other":{"name":"Other bookmarks","type":"folder","children":[{"type":"url","name":"Old","url":"http://old.example/"}]},
          "synced":{"name":"Mobile","type":"folder","children":[]}
        }}
        """#
        let tree = BrowserImportFormat.chromiumBookmarks(Data(json.utf8))

        #expect(tree.items.map(\.title) == ["Site"])
        #expect(tree.folders.map(\.title) == ["Work", "Other bookmarks"])
        #expect(tree.folders[0].items.map(\.title) == ["Doc"])
    }

    @Test func damagedBookmarkFileGivesNothing() {
        #expect(BrowserImportFormat.chromiumBookmarks(Data("{".utf8)) == BookmarkTree())
    }

    @Test func safariHistoryKeepsOnlyWebAddresses() {
        let json = #"{"history":[{"url":"https://a.example/","title":"A","time_usec":1000000,"visit_count":3},{"url":"file:///x","time_usec":1}]}"#
        let entries = BrowserImportFormat.safariHistory(Data(json.utf8))

        #expect(entries.map(\.title) == ["A"])
        #expect(entries[0].visitCount == 3)
        #expect(entries[0].lastVisit == Date(timeIntervalSince1970: 1))
    }

    @Test(arguments: [
        "name,url,username,password,note\nSite,https://a.example/,ada,\"p,a\"\"ss\nline\",\n",
        "\u{FEFF}Title,URL,Username,Password,Notes,OTPAuth\r\nSite,https://a.example/,ada,\"p,a\"\"ss\nline\",,\r\n",
        "\"url\",\"username\",\"password\",\"httpRealm\"\n\"https://a.example/\",\"ada\",\"p,a\"\"ss\nline\",\n",
    ]) func readsEachBrowsersPasswordFile(text: String) {
        #expect(BrowserImportFormat.passwordsCSV(text) == [
            ImportedLogin(url: "https://a.example/", username: "ada", password: "p,a\"ss\nline"),
        ])
    }

    @Test func fileWithoutPasswordColumnsGivesNothing() {
        #expect(BrowserImportFormat.passwordsCSV("a,b\n1,2\n").isEmpty)
    }

    @Test func importingKeepsNewerPasswordsAndRefusesPlainHTTP() async throws {
        let store = FakeStore(saved: [SavedLogin(origin: "https://a.example", username: "ada"): "newer"])
        let added = try await BrowserImportFormat.save([
            ImportedLogin(url: "https://a.example/login", username: "ada", password: "older"),
            ImportedLogin(url: "https://a.example/login", username: "bob", password: "first"),
            ImportedLogin(url: "https://a.example/other", username: "bob", password: "second"),
            ImportedLogin(url: "http://plain.example/", username: "ada", password: "exposed"),
            ImportedLogin(url: "android://hash@com.app/", username: "ada", password: "app"),
        ], to: store)

        #expect(added == 1)
        #expect(await store.saved == [
            SavedLogin(origin: "https://a.example", username: "ada"): "newer",
            SavedLogin(origin: "https://a.example", username: "bob"): "first",
        ])
    }

    private actor FakeStore: CredentialStoring {
        var saved: [SavedLogin: String]

        init(saved: [SavedLogin: String]) {
            self.saved = saved
        }

        func logins(for origin: String?) -> [SavedLogin] { Array(saved.keys) }
        func password(for login: SavedLogin) -> String? { saved[login] }
        func save(_ login: SavedLogin, password: String) { saved[login] = password }
        func delete(_ login: SavedLogin) { saved[login] = nil }
    }
}
