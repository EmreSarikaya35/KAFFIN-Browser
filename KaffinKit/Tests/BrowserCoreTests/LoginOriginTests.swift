import BrowserCore
import Foundation
import Testing

struct LoginOriginTests {
    @Test(arguments: [
        ("https://accounts.example.com/login?x=1", "https://accounts.example.com"),
        ("https://example.com:8443/a", "https://example.com:8443"),
        ("http://localhost:3000/", "http://localhost:3000"),
        ("http://127.0.0.1:8765/a", "http://127.0.0.1:8765"),
    ])
    func keepsExactOrigin(url: String, expected: String) {
        #expect(LoginOrigin.make(from: URL(string: url)) == expected)
    }

    @Test(arguments: ["http://example.com/login", "about:blank", "file:///tmp/a.html", "data:text/html,x"])
    func refusesUnencryptedAndLocalPages(url: String) {
        #expect(LoginOrigin.make(from: URL(string: url)) == nil)
    }

    @Test func subdomainIsDifferentSite() {
        #expect(LoginOrigin.make(from: URL(string: "https://a.example.com"))
            != LoginOrigin.make(from: URL(string: "https://b.example.com")))
    }
}
