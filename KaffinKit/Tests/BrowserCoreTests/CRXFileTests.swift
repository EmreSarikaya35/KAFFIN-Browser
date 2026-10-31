import BrowserCore
import CryptoKit
import Foundation
import Security
import Testing

/// Builds real CRX3 packages, signed with keys made for the test.
private struct SignedPackage {
    enum Algorithm { case rsa, ecdsa }

    let spki: Data
    let privateKey: SecKey
    let algorithm: Algorithm

    init(_ algorithm: Algorithm = .rsa) throws {
        self.algorithm = algorithm
        let attributes: [String: Any] = algorithm == .rsa
            ? [kSecAttrKeyType as String: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits as String: 2048]
            : [kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom, kSecAttrKeySizeInBits as String: 256]
        privateKey = try #require(SecKeyCreateRandomKey(attributes as CFDictionary, nil))
        let publicKey = try #require(SecKeyCopyPublicKey(privateKey))
        let raw = try #require(SecKeyCopyExternalRepresentation(publicKey, nil)) as Data
        let identifier = Self.der(0x30, Data(repeating: 1, count: 13))
        spki = Self.der(0x30, identifier + Self.der(0x03, Data([0]) + raw))
    }

    static func der(_ tag: UInt8, _ content: Data) -> Data {
        var length = Data()
        if content.count < 128 {
            length.append(UInt8(content.count))
        } else {
            var bytes = withUnsafeBytes(of: UInt32(content.count).bigEndian) { Data($0) }
            while bytes.first == 0 { bytes.removeFirst() }
            length.append(0x80 | UInt8(bytes.count))
            length.append(bytes)
        }
        return Data([tag]) + length + content
    }

    static func varint(_ value: Int) -> Data {
        var value = value
        var bytes = Data()
        repeat {
            bytes.append(UInt8(value & 0x7F) | (value > 0x7F ? 0x80 : 0))
            value >>= 7
        } while value > 0
        return bytes
    }

    static func field(_ number: Int, _ payload: Data) -> Data {
        varint(number << 3 | 2) + varint(payload.count) + payload
    }

    var id: String {
        let digest = Data(SHA256.hash(data: spki)).prefix(16)
        return String(digest.flatMap { [$0 >> 4, $0 & 15] }.map { Character(UnicodeScalar(97 + $0)) })
    }

    var idBytes: Data { Data(SHA256.hash(data: spki)).prefix(16) }

    func build(archive: Data, claimedID: Data? = nil, tamper: (Data) -> Data = { $0 }) throws -> Data {
        let signedData = Self.field(1, claimedID ?? idBytes)
        var message = Data("CRX3 SignedData\0".utf8)
        message += withUnsafeBytes(of: UInt32(signedData.count).littleEndian) { Data($0) }
        message += signedData + archive

        let algorithmName: SecKeyAlgorithm = algorithm == .rsa
            ? .rsaSignatureMessagePKCS1v15SHA256
            : .ecdsaSignatureMessageX962SHA256
        let signature = try #require(SecKeyCreateSignature(privateKey, algorithmName, message as CFData, nil)) as Data
        let proof = Self.field(1, spki) + Self.field(2, signature)
        let header = Self.field(algorithm == .rsa ? 2 : 3, proof) + Self.field(10000, signedData)

        let size = withUnsafeBytes(of: UInt32(header.count).littleEndian) { Data($0) }
        let version = Data([3, 0, 0, 0])
        return Data("Cr24".utf8) + version + size + header + tamper(archive)
    }
}

struct CRXFileTests {
    private let zip = Data("PK\u{3}\u{4}archive".utf8)

    @Test(arguments: [SignedPackage.Algorithm.rsa, .ecdsa])
    fileprivate func acceptsValidSignature(algorithm: SignedPackage.Algorithm) throws {
        let package = try SignedPackage(algorithm)
        let file = try package.build(archive: zip)

        #expect(CRXFile.zipArchive(from: file, expectedID: package.id) == zip)
        #expect(CRXFile.zipArchive(from: file, expectedID: nil) == zip)
    }

    @Test func refusesChangedArchive() throws {
        let package = try SignedPackage()
        let file = try package.build(archive: zip) { $0 + Data([0]) }
        #expect(CRXFile.zipArchive(from: file, expectedID: nil) == nil)
    }

    @Test func refusesValidPackageOfAnotherExtension() throws {
        let package = try SignedPackage()
        let other = try SignedPackage()
        let file = try package.build(archive: zip)
        #expect(CRXFile.zipArchive(from: file, expectedID: other.id) == nil)
    }

    @Test func refusesPackageClaimingAnIdentifierItsKeyDoesNotOwn() throws {
        let attacker = try SignedPackage()
        let victim = try SignedPackage()
        let file = try attacker.build(archive: zip, claimedID: victim.idBytes)
        #expect(CRXFile.zipArchive(from: file, expectedID: victim.id) == nil)
    }

    @Test func plainZipOnlyPassesWhenNoExtensionIsExpected() {
        #expect(CRXFile.zipArchive(from: zip, expectedID: nil) == zip)
        #expect(CRXFile.zipArchive(from: zip, expectedID: "ddkjiahejlhfcafbddmgiahcphecmpfh") == nil)
    }

    @Test func refusesUnsignedOldFormat() {
        let file = Data("Cr24".utf8) + Data([2, 0, 0, 0, 4, 0, 0, 0, 8, 0, 0, 0]) + Data(repeating: 1, count: 12) + zip
        #expect(CRXFile.zipArchive(from: file, expectedID: nil) == nil)
    }

    private static func bytes(_ values: [UInt8]) -> Data {
        Data("Cr24".utf8) + Data(values)
    }

    private static let damagedFiles: [Data] = [
        Data("not a package".utf8),
        bytes([]),
        bytes([3, 0, 0, 0]),
        bytes([3, 0, 0, 0, 255, 255, 255, 255]),
        bytes([3, 0, 0, 0, 4, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF, 0x50, 0x4B]),
        bytes([9, 0, 0, 0] + [UInt8](repeating: 0, count: 40)),
    ]

    @Test(arguments: damagedFiles)
    func refusesDamagedFiles(data: Data) {
        #expect(CRXFile.zipArchive(from: data, expectedID: nil) == nil)
    }

    @Test func refusesLengthsThatRunPastTheHeader() throws {
        let header = SignedPackage.varint(10000 << 3 | 2) + SignedPackage.varint(1_000_000)
        let size = withUnsafeBytes(of: UInt32(header.count).littleEndian) { Data($0) }
        let file = Data("Cr24".utf8) + Data([3, 0, 0, 0]) + size + header + zip
        #expect(CRXFile.zipArchive(from: file, expectedID: nil) == nil)
    }

    @Test func refusesHeaderWithoutProof() {
        let signed = SignedPackage.field(1, Data(repeating: 1, count: 16))
        let header = SignedPackage.field(10000, signed)
        let size = withUnsafeBytes(of: UInt32(header.count).littleEndian) { Data($0) }
        let file = Data("Cr24".utf8) + Data([3, 0, 0, 0]) + size + header + zip
        #expect(CRXFile.zipArchive(from: file, expectedID: nil) == nil)
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
