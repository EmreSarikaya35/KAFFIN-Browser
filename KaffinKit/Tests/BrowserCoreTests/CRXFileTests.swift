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

    @Test func foreignSiteCannotPoseAsListing() {
        #expect(ChromeWebStore.extensionID(from: "https://evil.example/detail/x/\(id)") == nil)
    }

    @Test func downloadAddressCarriesTheIdentifier() {
        let url = ChromeWebStore.packageURL(for: id)
        #expect(url.host() == "clients2.google.com")
        #expect(url.absoluteString.contains("id%3D\(id)"))
    }
}
