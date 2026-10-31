import AppKit
import CryptoKit
import Foundation
import Observation
import Security

/// A CRX is a ZIP archive behind a signed header. The extension's identifier comes from the
/// publisher's public key, so a valid signature proves the package really is that extension.
public enum CRXFile {
    private static let zipMagic = Data([0x50, 0x4B, 0x03, 0x04])
    private static let signaturePrefix = Data("CRX3 SignedData\0".utf8)

    private struct Proof {
        let publicKey: Data
        let signature: Data
        let isRSA: Bool
    }

    /// Returns the archive only if the package passes verification.
    /// With `expectedID`, it must be that exact extension and a plain ZIP is refused.
    public static func zipArchive(from file: Data, expectedID: String?) -> Data? {
        let data = Data(file)
        if data.starts(with: zipMagic) { return expectedID == nil ? data : nil }
        // Version 2 had weaker signatures, and Chrome itself stopped accepting it.
        guard data.starts(with: Data("Cr24".utf8)), word(in: data, at: 4) == 3,
              let headerSize = word(in: data, at: 8), headerSize < data.count - 12 else { return nil }

        let archive = Data(data.suffix(from: 12 + headerSize))
        guard archive.starts(with: zipMagic),
              let (proofs, signedData) = parseHeader(data.subdata(in: 12..<(12 + headerSize))),
              let claimedID = identifier(in: signedData) else { return nil }
        if let expectedID, identifierText(claimedID) != expectedID { return nil }

        var message = signaturePrefix
        message.append(contentsOf: withUnsafeBytes(of: UInt32(signedData.count).littleEndian) { Array($0) })
        message.append(signedData)
        message.append(archive)
        let isValid = proofs.contains { proof in
            Data(SHA256.hash(data: proof.publicKey)).prefix(16) == claimedID && verify(proof, message: message)
        }
        return isValid ? archive : nil
    }

    private static func parseHeader(_ header: Data) -> (proofs: [Proof], signedData: Data)? {
        var reader = ProtoReader(header)
        var proofs: [Proof] = []
        var signedData: Data?
        while let field = reader.next() {
            switch field.number {
            case 2, 3:
                guard let proof = parseProof(field.payload, isRSA: field.number == 2) else { return nil }
                proofs.append(proof)
            case 10000:
                signedData = field.payload
            default:
                break
            }
        }
        guard reader.isAtEnd, let signedData, !proofs.isEmpty else { return nil }
        return (proofs, signedData)
    }

    private static func parseProof(_ data: Data, isRSA: Bool) -> Proof? {
        var reader = ProtoReader(data)
        var publicKey: Data?
        var signature: Data?
        while let field = reader.next() {
            if field.number == 1 { publicKey = field.payload }
            if field.number == 2 { signature = field.payload }
        }
        guard reader.isAtEnd, let publicKey, let signature else { return nil }
        return Proof(publicKey: publicKey, signature: signature, isRSA: isRSA)
    }

    private static func identifier(in signedData: Data) -> Data? {
        var reader = ProtoReader(signedData)
        while let field = reader.next() {
            if field.number == 1, field.payload.count == 16 { return field.payload }
        }
        return nil
    }

    private static func identifierText(_ bytes: Data) -> String {
        String(bytes.flatMap { [$0 >> 4, $0 & 15] }.map { Character(UnicodeScalar(97 + $0)) })
    }

    private static func verify(_ proof: Proof, message: Data) -> Bool {
        guard let rawKey = keyBits(inSubjectPublicKeyInfo: proof.publicKey) else { return false }
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: proof.isRSA ? kSecAttrKeyTypeRSA : kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ]
        guard let key = SecKeyCreateWithData(rawKey as CFData, attributes as CFDictionary, nil) else { return false }
        let algorithm: SecKeyAlgorithm = proof.isRSA ? .rsaSignatureMessagePKCS1v15SHA256 : .ecdsaSignatureMessageX962SHA256
        return SecKeyVerifySignature(key, algorithm, message as CFData, proof.signature as CFData, nil)
    }

    /// Reads SEQUENCE { SEQUENCE algorithm, BIT STRING key }. Security.framework wants only the key.
    private static func keyBits(inSubjectPublicKeyInfo der: Data) -> Data? {
        guard let outer = derValue(der, at: 0, tag: 0x30),
              let algorithm = derValue(outer.value, at: 0, tag: 0x30),
              let bits = derValue(outer.value, at: algorithm.end, tag: 0x03),
              bits.value.first == 0 else { return nil }
        return Data(bits.value.dropFirst())
    }

    private static func derValue(_ data: Data, at offset: Int, tag: UInt8) -> (value: Data, end: Int)? {
        let data = Data(data)
        guard offset + 2 <= data.count, data[offset] == tag else { return nil }
        var start = offset + 2
        var length = Int(data[offset + 1])
        if length >= 0x80 {
            let count = length & 0x7F
            guard (1...4).contains(count), start + count <= data.count else { return nil }
            length = data[start..<(start + count)].reduce(0) { $0 << 8 | Int($1) }
            start += count
        }
        guard length <= data.count - start else { return nil }
        return (data.subdata(in: start..<(start + length)), start + length)
    }

    private static func word(in data: Data, at offset: Int) -> Int? {
        guard data.count >= offset + 4 else { return nil }
        return (0..<4).reduce(0) { $0 | Int(data[offset + $1]) << ($1 * 8) }
    }

    /// Just enough protobuf for the CRX header. Any malformed field stops it, leaving `isAtEnd` false.
    private struct ProtoReader {
        private let data: Data
        private var offset = 0

        init(_ data: Data) {
            self.data = Data(data)
        }

        var isAtEnd: Bool { offset == data.count }

        private mutating func varint() -> Int? {
            var value = 0
            for shift in stride(from: 0, to: 63, by: 7) {
                guard offset < data.count else { return nil }
                let byte = data[offset]
                offset += 1
                value |= Int(byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
            }
            return nil
        }

        mutating func next() -> (number: Int, payload: Data)? {
            let start = offset
            guard !isAtEnd, let key = varint() else { return nil }
            switch key & 7 {
            case 0:
                if varint() != nil { return (key >> 3, Data()) }
            case 2:
                if let length = varint(), length >= 0, length <= data.count - offset {
                    defer { offset += length }
                    return (key >> 3, data.subdata(in: offset..<(offset + length)))
                }
            default:
                break
            }
            offset = start
            return nil
        }
    }
}

public enum ExtensionInstallError: Error, Equatable {
    case declined
    case notAnExtension
    case tooLarge
}

public struct ExtensionEntry: Identifiable {
    public let id: String
    public let name: String
    public let version: String
    public let isEnabled: Bool
    public let problems: [String]
    public let icon: NSImage?
    /// Set when the extension came from the Chrome Web Store.
    public let storeID: String?
    public let isPinned: Bool
    /// Short text the extension shows over its icon, like a count of blocked requests.
    public let badge: String

    public init(
        id: String,
        name: String,
        version: String,
        isEnabled: Bool,
        problems: [String],
        icon: NSImage?,
        storeID: String?,
        isPinned: Bool,
        badge: String
    ) {
        self.id = id
        self.name = name
        self.version = version
        self.isEnabled = isEnabled
        self.problems = problems
        self.icon = icon
        self.storeID = storeID
        self.isPinned = isPinned
        self.badge = badge
    }
}

@MainActor
public protocol ExtensionCommands: AnyObject {
    func install(from url: URL) async throws
    func installFromStore(id: String) async throws
    func setEnabled(_ id: String, _ isEnabled: Bool)
    func setPinned(_ id: String, _ isPinned: Bool)
    func remove(_ id: String) async
    func performAction(_ id: String)
}

/// What the interface sees of a profile's extensions. The WebKit objects stay behind `commands`.
@MainActor
@Observable
public final class ExtensionsModel {
    public var entries: [ExtensionEntry] = []
    @ObservationIgnored public weak var commands: (any ExtensionCommands)?
    /// Checking sends installed extension identifiers to Google, so it can be turned off.
    public var checksForUpdates: Bool {
        didSet { defaults.set(checksForUpdates, forKey: Self.updatesKey) }
    }

    private static let updatesKey = "checksExtensionUpdates"
    @ObservationIgnored private let defaults: UserDefaults

    public init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        checksForUpdates = defaults.object(forKey: Self.updatesKey) as? Bool ?? true
    }

    public func isInstalled(storeID: String) -> Bool {
        entries.contains { $0.storeID == storeID }
    }
}

/// The store's Add button only works in Chrome, so a listing's address or identifier stands in for it.
public enum ChromeWebStore {
    private static let hosts: Set<String> = ["chromewebstore.google.com", "chrome.google.com"]

    /// Identifiers are 32 letters from a to p.
    public static func extensionID(from text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isIdentifier(text) { return text }
        guard let url = URL(string: text), let host = url.host()?.lowercased(), hosts.contains(host) else { return nil }
        return url.pathComponents.first(where: isIdentifier)
    }

    private static func isIdentifier(_ text: String) -> Bool {
        text.count == 32 && text.allSatisfy { ("a"..."p").contains($0) }
    }

    /// The extension a page lists. Stricter than typed text: only an encrypted store page counts.
    public static func listingID(of url: URL?) -> String? {
        guard let url, url.scheme == "https" else { return nil }
        return extensionID(from: url.absoluteString)
    }

    public static func updateCheckURL(for versions: [String: String]) -> URL {
        let extensions = versions.sorted { $0.key < $1.key }.map { "&x=id%3D\($0.key)%26v%3D\($0.value)%26uc" }
        return URL(string: "https://clients2.google.com/service/update2/crx?response=updatecheck"
            + "&prodversion=156.0.0.0&acceptformat=crx2,crx3" + extensions.joined())!
    }

    /// Extensions with a newer release, from the update service's XML. Bad data simply means no updates.
    public static func availableVersions(in response: Data) -> [String: String] {
        let reader = UpdateResponseReader()
        let parser = XMLParser(data: response)
        parser.delegate = reader
        return parser.parse() ? reader.versions : [:]
    }

    /// Compares each dotted number, so 1.10 is newer than 1.9, and 1.2 equals 1.2.0.
    public static func isNewer(_ version: String, than current: String) -> Bool {
        let new = version.split(separator: ".").map { Int($0) ?? 0 }
        let old = current.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(new.count, old.count) {
            let left = index < new.count ? new[index] : 0
            let right = index < old.count ? old[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    private final class UpdateResponseReader: NSObject, XMLParserDelegate {
        var versions: [String: String] = [:]
        private var currentID: String?

        func parser(
            _ parser: XMLParser,
            didStartElement name: String,
            namespaceURI: String?,
            qualifiedName: String?,
            attributes: [String: String]
        ) {
            if name == "app" { currentID = attributes["appid"] }
            if name == "updatecheck", let currentID, let version = attributes["version"] {
                versions[currentID] = version
            }
        }
    }

    public static func packageURL(for id: String) -> URL {
        // `prodversion` must look current, or the service refuses the request.
        URL(string: "https://clients2.google.com/service/update2/crx?response=redirect&prodversion=156.0.0.0"
            + "&acceptformat=crx2,crx3&x=id%3D\(id)%26uc")!
    }
}
