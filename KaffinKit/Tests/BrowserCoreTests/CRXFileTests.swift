import BrowserCore
import Foundation
import Testing

struct CRXFileTests {
    private let zip = Data("PK\u{3}\u{4}archive".utf8)

    private func littleEndian(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.littleEndian) { Data($0) }
    }

    @Test func removesVersion3Header() {
        let header = Data(repeating: 7, count: 20)
        let file = Data("Cr24".utf8) + littleEndian(3) + littleEndian(20) + header + zip
        #expect(CRXFile.zipArchive(from: file) == zip)
    }

    @Test func removesVersion2Header() {
        let file = Data("Cr24".utf8) + littleEndian(2) + littleEndian(4) + littleEndian(8)
            + Data(repeating: 1, count: 12) + zip
        #expect(CRXFile.zipArchive(from: file) == zip)
    }

    @Test func plainZipPassesThrough() {
        #expect(CRXFile.zipArchive(from: zip) == zip)
    }

    @Test(arguments: [
        Data("not a package".utf8),
        Data("Cr24".utf8),
        Data("Cr24".utf8) + Data([3, 0, 0, 0]),
        Data("Cr24".utf8) + Data([9, 0, 0, 0]) + Data(repeating: 0, count: 40),
    ])
    func refusesWhatIsNotAPackage(data: Data) {
        #expect(CRXFile.zipArchive(from: data) == nil)
    }

    @Test func headerLongerThanFileIsRefused() {
        let file = Data("Cr24".utf8) + littleEndian(3) + littleEndian(UInt32.max)
        #expect(CRXFile.zipArchive(from: file) == nil)
    }

    @Test func archiveAfterHeaderMustBeZip() {
        let file = Data("Cr24".utf8) + littleEndian(3) + littleEndian(2) + Data([0, 0]) + Data("nope".utf8)
        #expect(CRXFile.zipArchive(from: file) == nil)
    }
}

struct ChromeWebStoreTests {
    private let id = "ddkjiahejlhfcafbddmgiahcphecmpfh"

    @Test func acceptsListingAddressesAndBareIdentifiers() {
        #expect(ChromeWebStore.extensionID(from: "https://chromewebstore.google.com/detail/ublock-origin-lite/\(id)?hl=tr") == id)
        #expect(ChromeWebStore.extensionID(from: "https://chrome.google.com/webstore/detail/name/\(id)") == id)
        #expect(ChromeWebStore.extensionID(from: "  \(id)  ") == id)
    }

    @Test(arguments: ["", "not an extension", "https://example.com/detail/name", "ABCDEFGHIJKLMNOPABCDEFGHIJKLMNOP"])
    func refusesAnythingElse(text: String) {
        #expect(ChromeWebStore.extensionID(from: text) == nil)
    }

    @Test func pageListingsNeedAnEncryptedStoreAddress() {
        #expect(ChromeWebStore.listingID(of: URL(string: "https://chromewebstore.google.com/detail/name/\(id)")) == id)
        #expect(ChromeWebStore.listingID(of: URL(string: "http://chromewebstore.google.com/detail/name/\(id)")) == nil)
        #expect(ChromeWebStore.listingID(of: URL(string: "https://chromewebstore.google.com/category/extensions")) == nil)
        #expect(ChromeWebStore.listingID(of: URL(string: "https://evil.example/detail/name/\(id)")) == nil)
        #expect(ChromeWebStore.listingID(of: nil) == nil)
    }

    @Test func foreignSiteCannotPoseAsListing() {
        #expect(ChromeWebStore.extensionID(from: "https://evil.example/detail/x/\(id)") == nil)
    }

    @Test func readsAvailableVersionsAndIgnoresUpToDateEntries() {
        let response = Data("""
        <?xml version="1.0" encoding="UTF-8"?>
        <gupdate xmlns="http://www.google.com/update2/response" protocol="2.0">
          <app appid="\(id)" status="ok"><updatecheck codebase="https://x/y.crx" version="2.0.1" status="ok"/></app>
          <app appid="aaaabbbbccccddddeeeeffffgggghhhh" status="ok"><updatecheck status="noupdate"/></app>
        </gupdate>
        """.utf8)
        #expect(ChromeWebStore.availableVersions(in: response) == [id: "2.0.1"])
    }

    @Test func malformedUpdateResponseMeansNoUpdates() {
        #expect(ChromeWebStore.availableVersions(in: Data("<not xml".utf8)).isEmpty)
    }

    @Test(arguments: [
        ("1.10", "1.9", true),
        ("2026.1026.1812", "2026.1026.1811", true),
        ("1.2", "1.2", false),
        ("1.2", "1.2.0", false),
        ("1.2.1", "1.2", true),
        ("1.1", "1.2", false),
    ])
    func comparesVersionsNumerically(new: String, old: String, expected: Bool) {
        #expect(ChromeWebStore.isNewer(new, than: old) == expected)
    }

    @Test func updateCheckNamesEachExtension() {
        let url = ChromeWebStore.updateCheckURL(for: [id: "1.0"])
        #expect(url.absoluteString.contains("response=updatecheck"))
        #expect(url.absoluteString.contains("id%3D\(id)%26v%3D1.0%26uc"))
    }

    @Test func downloadAddressCarriesTheIdentifier() {
        let url = ChromeWebStore.packageURL(for: id)
        #expect(url.host() == "clients2.google.com")
        #expect(url.absoluteString.contains("id%3D\(id)"))
    }
}
