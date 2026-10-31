import AppKit
import CoreServices
import Foundation
import OSLog
import Observation
import WebKit

@MainActor
@Observable
public final class DownloadItem: Identifiable {
    public enum State: Equatable {
        case downloading
        case finished
        case cancelled
        case failed(String)
    }

    public let id = UUID()
    public fileprivate(set) var fileName: String
    public fileprivate(set) var state = State.downloading
    public fileprivate(set) var fraction = 0.0
    public fileprivate(set) var destination: URL?

    @ObservationIgnored fileprivate let download: WKDownload
    @ObservationIgnored fileprivate var progress: NSKeyValueObservation?
    @ObservationIgnored fileprivate var stagedFile: URL?

    fileprivate init(download: WKDownload) {
        self.download = download
        fileName = download.originalRequest?.url?.lastPathComponent ?? ""
    }
}

/// Lives above the tabs, and WKDownload outlives its WebView, so closing or sleeping a tab keeps a download running.
///
/// In the sandbox, WebKit's network process can write to the app's container but not to the user's Downloads folder,
/// and the download stalls without an error. Files are therefore staged in the container, then moved by the app,
/// which holds the Downloads entitlement.
// shortcut: no pause, resume or retry yet; WebKit only offers cancel with resume data. Add with the Downloads page.
@MainActor
@Observable
public final class DownloadManager: NSObject, WKDownloadDelegate {
    private static let logger = Logger(subsystem: "com.kaffin.browser", category: "Downloads")

    public nonisolated static let stagingRoot = FileManager.default.temporaryDirectory.appending(path: "KAFFIN-Downloads")

    public private(set) var items: [DownloadItem] = []
    @ObservationIgnored private let directory: URL?

    /// Without a directory, files go to the user's Downloads folder.
    public init(directory: URL? = nil) {
        self.directory = directory
    }

    private var folder: URL? {
        directory ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
    }

    private func item(for download: WKDownload) -> DownloadItem? {
        items.first { $0.download === download }
    }

    public func attach(_ download: WKDownload) {
        download.delegate = self
        let item = DownloadItem(download: download)
        items.insert(item, at: 0)
        item.progress = download.progress.observe(\.fractionCompleted) { [weak item] progress, _ in
            let fraction = progress.fractionCompleted
            Task { @MainActor in
                // Progress fires per network chunk; a whole-percent step is enough for the UI.
                if let item, fraction - item.fraction >= 0.01 { item.fraction = fraction }
            }
        }
    }

    public func cancel(_ item: DownloadItem) {
        guard item.state == .downloading else { return }
        item.state = .cancelled
        item.progress = nil
        item.download.cancel { [weak self] _ in
            Task { @MainActor in self?.removeStagingFolder(of: item) }
        }
    }

    public func remove(_ item: DownloadItem) {
        if item.state != .downloading { items.removeAll { $0 === item } }
    }

    public func reveal(_ item: DownloadItem) {
        if let destination = item.destination {
            NSWorkspace.shared.activateFileViewerSelecting([destination])
        }
    }

    public func open(_ item: DownloadItem) {
        if let destination = item.destination { NSWorkspace.shared.open(destination) }
    }

    public func download(
        _ download: WKDownload,
        decideDestinationUsing response: URLResponse,
        suggestedFilename: String
    ) async -> URL? {
        let staging = Self.stagingRoot.appending(path: UUID().uuidString)
        do {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        } catch {
            fail(item(for: download), error)
            return nil
        }
        let destination = DownloadRules.destination(for: suggestedFilename, in: staging)
        if let item = item(for: download) {
            item.fileName = destination.lastPathComponent
            item.stagedFile = destination
        }
        return destination
    }

    public func downloadDidFinish(_ download: WKDownload) {
        guard let item = item(for: download), let staged = item.stagedFile, let folder else { return }
        item.progress = nil
        defer { removeStagingFolder(of: item) }
        do {
            try markQuarantined(staged, source: download.originalRequest?.url)
            let target = DownloadRules.destination(for: item.fileName, in: folder)
            try FileManager.default.moveItem(at: staged, to: target)
            item.destination = target
            item.fileName = target.lastPathComponent
            item.fraction = 1
            item.state = .finished
        } catch {
            fail(item, error)
        }
    }

    public func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let item = item(for: download), item.state != .cancelled else { return }
        fail(item, error)
        removeStagingFolder(of: item)
    }

    private func fail(_ item: DownloadItem?, _ error: Error) {
        Self.logger.error("Download failed: \((error as NSError).domain, privacy: .public) \((error as NSError).code)")
        item?.state = .failed(error.localizedDescription)
        item?.progress = nil
    }

    /// Gatekeeper checks a downloaded app on first open only if this mark is present.
    private func markQuarantined(_ file: URL, source: URL?) throws {
        var properties: [String: Any] = [
            kLSQuarantineAgentNameKey as String: "KAFFIN",
            kLSQuarantineTypeKey as String: kLSQuarantineTypeWebDownload as String,
        ]
        properties[kLSQuarantineDataURLKey as String] = source
        var values = URLResourceValues()
        values.quarantineProperties = properties
        var file = file
        try file.setResourceValues(values)
    }

    private func removeStagingFolder(of item: DownloadItem) {
        if let staged = item.stagedFile {
            try? FileManager.default.removeItem(at: staged.deletingLastPathComponent())
        }
        item.stagedFile = nil
    }
}
