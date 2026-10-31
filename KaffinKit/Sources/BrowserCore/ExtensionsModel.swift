import AppKit
import Foundation
import Observation

/// CRX is a ZIP archive with a header in front.
public enum CRXFile {
    private static let zipMagic = Data([0x50, 0x4B, 0x03, 0x04])

    /// Returns the archive, or nil when the data is not a valid package. Signatures are not checked.
    public static func zipArchive(from data: Data) -> Data? {
        if data.starts(with: zipMagic) { return data }
        guard data.starts(with: Data("Cr24".utf8)), let version = word(in: data, at: 4) else { return nil }

        let start: Int?
        switch version {
        case 2:
            guard let key = word(in: data, at: 8), let signature = word(in: data, at: 12) else { return nil }
            start = 16 + key + signature
        case 3:
            start = word(in: data, at: 8).map { 12 + $0 }
        default:
            start = nil
        }
        guard let start, start < data.count else { return nil }
        let archive = data.suffix(from: data.startIndex + start)
        return archive.starts(with: zipMagic) ? Data(archive) : nil
    }

    private static func word(in data: Data, at offset: Int) -> Int? {
        guard data.count >= offset + 4 else { return nil }
        return (0..<4).reduce(0) { $0 | Int(data[data.startIndex + offset + $1]) << ($1 * 8) }
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

    public init() {}

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
