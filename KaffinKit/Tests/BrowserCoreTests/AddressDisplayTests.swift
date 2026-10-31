import BrowserCore
import Foundation
import Testing

struct AddressDisplayTests {
    @Test(arguments: [
        ("https://example.com/", "example.com"),
        ("https://www.example.com/a?b=1", "www.example.com/a?b=1"),
        ("http://example.com/", "http://example.com"),
        ("about:blank", ""),
    ])
    func trimsDisplayedAddress(url: String, expected: String) {
        #expect(AddressDisplay.text(for: URL(string: url)) == expected)
    }

    @Test func noURLShowsNothing() {
        #expect(AddressDisplay.text(for: nil) == "")
    }

    @Test func classifiesConnectionSecurity() {
        #expect(AddressDisplay.security(of: URL(string: "https://example.com")) == .secure)
        #expect(AddressDisplay.security(of: URL(string: "http://example.com")) == .notSecure)
        #expect(AddressDisplay.security(of: URL(string: "about:blank")) == .none)
        #expect(AddressDisplay.security(of: nil) == .none)
    }
}
