import BrowserCore
import Testing

struct AddressResolverTests {
    @Test(arguments: [
        ("https://example.com/a?b=1", "https://example.com/a?b=1"),
        ("example.com", "https://example.com"),
        ("sub.example.co.uk/path", "https://sub.example.co.uk/path"),
        ("example.com:8080/x", "https://example.com:8080/x"),
        ("localhost:3000", "http://localhost:3000"),
        ("127.0.0.1:8765/", "http://127.0.0.1:8765/"),
        ("  example.com  ", "https://example.com"),
        ("about:blank", "about:blank"),
    ])
    func loadsAddresses(input: String, expected: String) {
        #expect(AddressResolver.resolve(input)?.absoluteString == expected)
    }

    @Test(arguments: [
        ("kahve nasıl yapılır", "kahve%20nas%C4%B1l%20yap%C4%B1l%C4%B1r"),
        ("swift", "swift"),
        ("1.2", "1.2"),
        ("a&b=c", "a%26b%3Dc"),
        ("user@example.com", "user@example.com"),
        ("javascript:alert(1)", "javascript:alert(1)"),
        ("data:text/html,x", "data:text/html,x"),
        ("999.1.1.1", "999.1.1.1"),
    ])
    func searchesEverythingElse(input: String, query: String) {
        #expect(AddressResolver.resolve(input)?.absoluteString == "https://www.google.com/search?q=\(query)")
    }

    @Test func ignoresBlankInput() {
        #expect(AddressResolver.resolve("   ") == nil)
    }
}
