import BrowserCore
import Foundation
import Testing

struct FaviconLoaderTests {
    // A valid 1x1 PNG.
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==")!

    private actor Network {
        var requests: [URL] = []
        let responses: [URL: Data]

        init(_ responses: [URL: Data]) {
            self.responses = responses
        }

        func fetch(_ url: URL) async -> Data? {
            requests.append(url)
            return responses[url]
        }
    }

    private actor MemoryStore: FaviconStoring {
        var icons: [String: Data] = [:]

        func favicon(host: String) -> Data? { icons[host] }
        func saveFavicon(host: String, data: Data) { icons[host] = data }
    }

    private let first = URL(string: "https://example.com/missing.png")!
    private let second = URL(string: "https://example.com/icon.png")!

    @Test func triesCandidatesInOrderAndStoresFirstWorkingIcon() async {
        let network = Network([second: Self.png])
        let store = MemoryStore()
        let loader = FaviconLoader(store: store, fetch: network.fetch)

        let icon = await loader.icon(host: "example.com", candidates: [first, second])
        #expect(icon != nil)
        #expect(await network.requests == [first, second])
        #expect(await store.icons["example.com"] == icon)
    }

    @Test func secondRequestUsesNoNetwork() async {
        let network = Network([first: Self.png])
        let loader = FaviconLoader(store: nil, fetch: network.fetch)

        _ = await loader.icon(host: "example.com", candidates: [first])
        _ = await loader.icon(host: "example.com", candidates: [first])
        #expect(await network.requests.count == 1)
    }

    @Test func storedIconAvoidsNetworkAfterRestart() async {
        let network = Network([:])
        let store = MemoryStore()
        await store.saveFavicon(host: "example.com", data: Self.png)
        let loader = FaviconLoader(store: store, fetch: network.fetch)

        #expect(await loader.icon(host: "example.com", candidates: [first]) == Self.png)
        #expect(await network.requests.isEmpty)
    }

    @Test func failedHostIsNotRetriedEveryPage() async {
        let network = Network([:])
        let loader = FaviconLoader(store: nil, fetch: network.fetch)

        #expect(await loader.icon(host: "example.com", candidates: [first]) == nil)
        #expect(await loader.icon(host: "example.com", candidates: [first]) == nil)
        #expect(await network.requests.count == 1)
    }

    @Test func nonImageDataIsRejected() async {
        let network = Network([first: Data("<html>not an image</html>".utf8)])
        let loader = FaviconLoader(store: nil, fetch: network.fetch)
        #expect(await loader.icon(host: "example.com", candidates: [first]) == nil)
    }

    @Test func nonWebSchemesAreNeverFetched() async {
        let network = Network([:])
        let loader = FaviconLoader(store: nil, fetch: network.fetch)
        _ = await loader.icon(host: "example.com", candidates: [URL(string: "file:///etc/passwd")!])
        #expect(await network.requests.isEmpty)
    }

    @Test func largeIconIsScaledDown() throws {
        let image = try #require(FaviconLoader.normalized(Self.png))
        #expect(image.count < 4096)
    }
}
