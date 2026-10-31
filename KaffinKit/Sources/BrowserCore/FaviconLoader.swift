import Foundation
import ImageIO
import UniformTypeIdentifiers

public protocol FaviconStoring: Sendable {
    func favicon(host: String) async throws -> Data?
    func saveFavicon(host: String, data: Data) async throws
}

/// WebKit has no favicon API, so icons are fetched here, once per host.
public actor FaviconLoader {
    private static let maximumDownload = 1_000_000
    private static let iconPixels = 64

    private static let session: URLSession = {
        // Ephemeral, so fetching an icon sends no cookies and leaves no tracking state.
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        return URLSession(configuration: configuration)
    }()

    private let store: (any FaviconStoring)?
    private let fetch: @Sendable (URL) async -> Data?
    private var memory: [String: Data] = [:]
    private var settled: Set<String> = []

    public init(
        store: (any FaviconStoring)?,
        fetch: @escaping @Sendable (URL) async -> Data? = FaviconLoader.download
    ) {
        self.store = store
        self.fetch = fetch
    }

    public func cached(host: String) async -> Data? {
        if let icon = memory[host] { return icon }
        guard let stored = try? await store?.favicon(host: host) else { return nil }
        memory[host] = stored
        return stored
    }

    /// Each host is attempted once per launch, so a site without an icon costs no repeated requests.
    public func icon(host: String, candidates: [URL]) async -> Data? {
        if let icon = await cached(host: host) { return icon }
        guard settled.insert(host).inserted else { return nil }

        for url in candidates where url.scheme == "https" || url.scheme == "http" {
            guard let data = await fetch(url), let icon = Self.normalized(data) else { continue }
            memory[host] = icon
            try? await store?.saveFavicon(host: host, data: icon)
            return icon
        }
        return nil
    }

    /// Re-encodes to a small PNG, so nothing a site sends is stored or decoded later as is.
    public nonisolated static func normalized(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
                  kCGImageSourceCreateThumbnailWithTransform: true,
                  kCGImageSourceThumbnailMaxPixelSize: iconPixels,
              ] as CFDictionary) else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
            return nil
        }
        CGImageDestinationAddImage(destination, image, nil)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    @Sendable
    public static func download(_ url: URL) async -> Data? {
        guard let (bytes, response) = try? await session.bytes(from: url),
              let status = (response as? HTTPURLResponse)?.statusCode, (200..<300).contains(status) else { return nil }
        var data = Data()
        do {
            for try await byte in bytes {
                data.append(byte)
                if data.count > maximumDownload { return nil }
            }
        } catch {
            return nil
        }
        return data
    }
}
